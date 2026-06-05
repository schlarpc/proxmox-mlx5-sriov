# proxmox-mellanox

SR-IOV VF provisioning for Mellanox ConnectX NICs on Proxmox VE, packaged as a
Debian `.deb` that is built by a Nix flake. Each VM gets a VF passed through
(near line-rate), while the host keeps vlan-aware switching control over those
VFs via hardware-offloaded eswitch representors bridged into a `vmbr`.

Built and tested against a ConnectX-6 Dx (`enp33s0f0np0`, `0000:21:00.0`) on the
`proxmox` node, but PF-agnostic: one systemd template instance per PF.

## The one idea that makes this make sense

Proxmox is a thin management layer over stock Debian. It is authoritative only
inside its own domains -- basically everything in `/etc/pve` plus its
ifupdown2-flavored `/etc/network/interfaces`. Everything else (kernel, mlx5,
sysfs, switchdev, systemd units) is plain Debian, with no single blessed path.

| Concern                          | Owner            | Mechanism (the "right way")                     |
| -------------------------------- | ---------------- | ----------------------------------------------- |
| VF -> VM attachment              | Proxmox (`/etc/pve`) | PCI resource mapping (`hostpci: mapping=...`) |
| Representor switching / VLANs    | Proxmox ifupdown2 | vlan-aware bridge in `/etc/network/interfaces`  |
| VF creation, switchdev, VF MACs  | **Debian (no native PVE feature)** | the `create-sriov-vfs` oneshot   |
| Resource-mapping registration    | Proxmox API      | `pvesh` in `sync-sriov-vf-mappings`             |

## Why two units per PF

The original single script tried to do everything at boot and logged
`ipcc_send_rec ... Connection refused` every time. Root cause: it ran
`Before=network-pre.target` (correct -- representors must exist before the
bridge comes up), but `pvesh` needs pmxcfs, and `pve-cluster.service` is ordered
`After=network.target`. You cannot satisfy both orderings in one unit -- it's a
dependency cycle. Hence the split, as **template units** keyed on the PF:

- **sriov-vfs@`<pf>`.service** -> `create-sriov-vfs <pf>`: switchdev + VFs +
  per-VF MACs. Runs `Before=network-pre.target`. No pve dependency.
- **sriov-vf-mappings@`<pf>`.service** -> `sync-sriov-vf-mappings <pf>`: `pvesh`
  mapping sync. `After=pve-cluster.service sriov-vfs@<pf>.service`,
  `Before=pve-guests.service`.

You enable only `sriov-vfs@<pf>`; it `Wants=` the mapping instance, which is
pulled in automatically and still runs late (at its own `After=pve-cluster`
ordering, not next to the early VF unit). One PF = one `systemctl enable`.
Multiple cards/ports = multiple instances, each independent (own `systemctl
status`, own failure isolation). Mapping IDs (`sriov-<pf>-vfN`) and the derived
MAC prefixes are per-PF, so instances never collide.

## Configuration is optional

There is no required config file. Everything is inferred:

| Input           | Source                                                              |
| --------------- | ------------------------------------------------------------------ |
| PF interface    | the systemd instance name (`%i`), e.g. `sriov-vfs@enp33s0f0np0`     |
| PF PCI address  | derived from the interface                                          |
| `VF_COUNT`      | `min(32, sriov_totalvfs)`, validated against the hardware ceiling   |
| `VF_MAC_PREFIX` | locally-administered prefix hashed from the PF's permanent MAC      |

To override the last two for a specific PF, drop a shell snippet at
`/etc/default/sriov-vfs.d/<interface>` (optional, sourced if present):

```sh
# /etc/default/sriov-vfs.d/enp33s0f0np0
VF_COUNT="16"
VF_MAC_PREFIX="36:7e:3a:0b:0b"
```

Set `VF_MAC_PREFIX` explicitly only if you coordinate MACs with DHCP
reservations or switch port-security; otherwise the derived one is stable per
host and unique across hosts. `create-sriov-vfs` logs the values it ends up
using.

## Layout

```
flake.nix                       Nix flake; `nix build .#deb`
package.nix                     derivation that drives dpkg-deb
bin/create-sriov-vfs            VFs + switchdev + deterministic MACs (early), takes <pf>
bin/sync-sriov-vf-mappings      pvesh resource-mapping sync (after pmxcfs), takes <pf>
systemd/sriov-vfs@.service              early template unit
systemd/sriov-vf-mappings@.service      late template unit
debian/                         control, postinst/postrm
udev/70-mlx5-vf-representors.rules   OPTIONAL: stable representor names (not packaged)
network/interfaces.snippet      OPTIONAL: matching bridge-ports line
```

## Build the .deb

```bash
nix build .#deb
ls -l result/        # -> result/sriov-vfs_<version>_all.deb
```

The build is hermetic and reproducible: `dpkg-deb` runs inside the derivation,
ownership is forced to `root:root` (`--root-owner-group`, no fakeroot), and
`SOURCE_DATE_EPOCH` (set by stdenv) clamps timestamps so the output is
bit-for-bit identical across machines (`nix build .#deb --rebuild` verifies it).
The package is `Architecture: all`. `nix develop` gives a shell with `dpkg` +
`shellcheck`.

## Install on the node

```bash
scp result/sriov-vfs_*_all.deb root@proxmox:/tmp/
ssh root@proxmox 'apt install -y /tmp/sriov-vfs_*_all.deb'   # or: dpkg -i
```

The package does **not** auto-enable anything (template units have no implicit
instance). Enable one unit per PF -- the mapping sync is pulled in
automatically:

```bash
systemctl enable sriov-vfs@enp33s0f0np0.service
```

They are boot-time provisioning units; let them run on the next reboot rather
than starting them under live guests. To validate the mapping half without
rebooting once VFs already exist: `systemctl start sriov-vf-mappings@<pf>`
(idempotent), then check the mappings.

### Migrating off the hand-placed setup

The live host currently runs **non-template** units placed by hand in
`/etc/systemd/system` (`sriov-vfs.service`, `sriov-vf-mappings.service`) that
call `/opt/schlarpc/bin/create-sriov-vfs` with no argument. Installing this
package overwrites those scripts with versions that **require** a `<pf>`
argument, so the old units would fail on next boot. Before/with installing:

```bash
systemctl disable --now sriov-vfs.service sriov-vf-mappings.service
rm /etc/systemd/system/sriov-vfs.service /etc/systemd/system/sriov-vf-mappings.service
rm -f /etc/systemd/system/sriov-vfs.service.bak-* /etc/systemd/system/sriov-vf-mappings.service.bak-*
# then install the .deb and enable the @<pf> instances as above
```

Note: the derived `VF_MAC_PREFIX` differs from the hand-placed scripts'
`36:7e:3a:0b:0b`. If anything downstream keys off the current VF MACs, pin it in
`/etc/default/sriov-vfs.d/enp33s0f0np0` before enabling.

## Optional: stable representor names

The bridge currently pins `eth0..eth31`, which are unstable kernel names. To make
them hardware-derived (`pf0vf0..pf0vf31`):

1. `install -m644 udev/70-mlx5-vf-representors.rules /etc/udev/rules.d/`
2. Edit `/etc/network/interfaces` `bridge-ports` to match `network/interfaces.snippet`.
3. Reboot in a maintenance window (both changes must land together).

Not in the .deb: shipping it active would rename the representors on the next
boot and break the bridge unless the interfaces change lands at the same time.

## Rollback

`apt remove sriov-vfs` (after `systemctl disable` of the instances). To return a
NIC to a clean state: `devlink dev eswitch set pci/<addr> mode legacy` and
`echo 0 > /sys/class/net/<pf>/device/sriov_numvfs`.
