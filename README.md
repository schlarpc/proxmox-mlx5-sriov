# proxmox-mlx5-sriov

SR-IOV VF provisioning for Mellanox ConnectX (mlx5) NICs on Proxmox VE, packaged
as a Debian `.deb` built by a Nix flake. Each VM gets a VF passed through (near
line-rate), while the host keeps vlan-aware switching control over those VFs via
hardware-offloaded eswitch representors bridged into a `vmbr`.

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
| VF creation, switchdev, VF MACs  | **Debian (no native PVE feature)** | `mlx5-sriov-create-vfs`          |
| Resource-mapping registration    | Proxmox API      | `pvesh` in `mlx5-sriov-sync-mappings`           |

## Networking assumptions (the opinionated part)

This package is shaped around one specific topology -- **switchdev-mode VFs as
vlan-aware trunk ports behind a hardware-offloaded bridge**. These are deliberate
choices, correct for that use case but wrong for others. Know them before reuse:

- **switchdev mode is forced.** `mlx5-sriov-create-vfs` always puts the eswitch
  in `switchdev`. This gives per-VF representors that can be bridged and offloaded
  to the NIC. The more common SR-IOV pattern -- **legacy mode**, where VFs sit
  directly on the wire with no representors and no host bridge -- is *not*
  supported here. If you want "VF straight onto VLAN 100", this is the wrong tool.
- **Every VF is a trunk; no per-VF VLAN is set.** The scripts assign no VLAN to
  the VFs. VLAN filtering happens in the vlan-aware bridge (a full `2-4094`
  trunk to each representor); the guest tags. There is no support for pinning a
  VF to a single access VLAN (`ip link set <pf> vf N vlan X`).
- **No per-VF `trust` / `spoofchk` / rate-limit knobs.** VFs keep the locked-down
  defaults (`spoofchk on`, `trust off`). VMs that emit multiple MACs or do their
  own VLAN tagging (routers, firewalls, nested virt, MACVLAN) would need
  `trust on` / `spoofchk off`, which this does not configure.
- **VFs get a forced administrative MAC.** Each VF is assigned a deterministic
  MAC (see below). With `spoofchk on` the guest cannot change it. If you want the
  guest to own its MAC, this isn't that.
- **The representor bridge is required but out of scope.** In switchdev mode a VF
  has *no path to the wire* until its representor is enslaved in a bridge. This
  package provisions VFs/MACs/mappings; it does **not** manage
  `/etc/network/interfaces`. You must build the vlan-aware bridge yourself --
  installing the package alone does not produce a working datapath.

Out of scope by design, not configurable: it is **mlx5-only** (the
`mlx5_core` rebind and `devlink eswitch` calls are Mellanox-specific), it
**re-creates VFs from scratch on every boot** (assumes exclusive ownership of the
PF's SR-IOV config), and it **bundles the Proxmox `pvesh` mapping step** (assumes
you are on PVE and want resource mappings).

## Why two units per PF

The original single script tried to do everything at boot and logged
`ipcc_send_rec ... Connection refused` every time. Root cause: it ran
`Before=network-pre.target` (correct -- representors must exist before the
bridge comes up), but `pvesh` needs pmxcfs, and `pve-cluster.service` is ordered
`After=network.target`. You cannot satisfy both orderings in one unit -- it's a
dependency cycle. Hence the split, as **template units** keyed on the PF:

- **mlx5-sriov-vfs@`<pf>`.service** -> `mlx5-sriov-create-vfs <pf>`: switchdev +
  VFs + per-VF MACs. Runs `Before=network-pre.target`. No pve dependency.
- **mlx5-sriov-mappings@`<pf>`.service** -> `mlx5-sriov-sync-mappings <pf>`:
  `pvesh` mapping sync. `After=pve-cluster.service mlx5-sriov-vfs@<pf>.service`,
  `Before=pve-guests.service`.

You enable only `mlx5-sriov-vfs@<pf>`; it `Wants=` the mapping instance, which is
pulled in automatically and still runs late (at its own `After=pve-cluster`
ordering, not next to the early VF unit). One PF = one `systemctl enable`.
Multiple cards/ports = multiple instances, each independent (own `systemctl
status`, own failure isolation). Mapping IDs (`sriov-<pf>-vfN`) and the derived
MAC prefixes are per-PF, so instances never collide.

## Configuration is optional

There is no required config file. Everything is inferred:

| Input           | Source                                                              |
| --------------- | ------------------------------------------------------------------ |
| PF interface    | the systemd instance name (`%i`), e.g. `mlx5-sriov-vfs@enp33s0f0np0`|
| PF PCI address  | derived from the interface                                          |
| `VF_COUNT`      | `min(32, sriov_totalvfs)`, validated against the hardware ceiling   |
| `VF_MAC_PREFIX` | locally-administered prefix hashed from the PF's permanent MAC      |

To override the last two for a specific PF, drop a shell snippet at
`/etc/default/mlx5-sriov.d/<interface>` (optional, sourced if present):

```sh
# /etc/default/mlx5-sriov.d/enp33s0f0np0
VF_COUNT="16"
VF_MAC_PREFIX="36:7e:3a:0b:0b"
```

Set `VF_MAC_PREFIX` explicitly only if you coordinate MACs with DHCP reservations
or switch port-security; otherwise the derived one is stable per host and unique
across hosts (the full PF MAC is hashed, so cards with sequential factory MACs
don't collide). `mlx5-sriov-create-vfs` logs the values it ends up using.

## Layout

```
flake.nix                       Nix flake; `nix build .#deb`
package.nix                     derivation that drives dpkg-deb
bin/mlx5-sriov-create-vfs       VFs + switchdev + deterministic MACs (early), takes <pf>
bin/mlx5-sriov-sync-mappings    pvesh resource-mapping sync (after pmxcfs), takes <pf>
systemd/mlx5-sriov-vfs@.service        early template unit (the one you enable)
systemd/mlx5-sriov-mappings@.service   late template unit (pulled in via Wants=)
debian/                         control, postinst/postrm
udev/70-mlx5-vf-representors.rules   OPTIONAL: stable representor names (not packaged)
network/interfaces.snippet      OPTIONAL: matching bridge-ports line
```

Installed paths: scripts in `/usr/sbin`, units in `/lib/systemd/system`, optional
overrides in `/etc/default/mlx5-sriov.d/`.

## Build the .deb

```bash
nix build .#deb
ls -l result/        # -> result/proxmox-mlx5-sriov_<version>_all.deb
```

The build is hermetic and reproducible: `dpkg-deb` runs inside the derivation,
ownership is forced to `root:root` (`--root-owner-group`, no fakeroot), and
`SOURCE_DATE_EPOCH` (set by stdenv) clamps timestamps so the output is
bit-for-bit identical across machines (`nix build .#deb --rebuild` verifies it).
The package is `Architecture: all`. `nix develop` gives a shell with `dpkg` +
`shellcheck`.

## Install on the node

```bash
scp result/proxmox-mlx5-sriov_*_all.deb root@proxmox:/tmp/
ssh root@proxmox 'apt install -y /tmp/proxmox-mlx5-sriov_*_all.deb'   # or: dpkg -i
```

The package does **not** auto-enable anything (template units have no implicit
instance). Enable one unit per PF -- the mapping sync is pulled in automatically:

```bash
systemctl enable mlx5-sriov-vfs@enp33s0f0np0.service
```

They are boot-time provisioning units; let them run on the next reboot rather
than starting them under live guests. To validate the mapping half without
rebooting once VFs already exist: `systemctl start mlx5-sriov-mappings@<pf>`
(idempotent), then check the mappings.

### Migrating off the hand-placed setup

The live host currently runs **non-template** units placed by hand in
`/etc/systemd/system` (`sriov-vfs.service`, `sriov-vf-mappings.service`) that call
`/opt/schlarpc/bin/...`. This package uses different names and FHS paths, so it
won't overwrite or shadow them -- but they would still run. Remove them when
adopting the package:

```bash
systemctl disable --now sriov-vfs.service sriov-vf-mappings.service
rm /etc/systemd/system/sriov-vfs.service /etc/systemd/system/sriov-vf-mappings.service
rm -f /etc/systemd/system/sriov-vf-mappings.service.bak-* \
      /etc/systemd/system/sriov-vfs.service.bak-*
rm -f /opt/schlarpc/bin/create-sriov-vfs* /opt/schlarpc/bin/sync-sriov-vf-mappings
# then install the .deb and: systemctl enable mlx5-sriov-vfs@enp33s0f0np0.service
```

Note: the derived `VF_MAC_PREFIX` differs from the hand-placed scripts'
`36:7e:3a:0b:0b`. If anything downstream keys off the current VF MACs, pin it in
`/etc/default/mlx5-sriov.d/enp33s0f0np0` before enabling.

## Optional: stable representor names

The bridge currently pins `eth0..eth31`, which are unstable kernel names. To make
them hardware-derived (`pf0vf0..pf0vf31`):

1. `install -m644 udev/70-mlx5-vf-representors.rules /etc/udev/rules.d/`
2. Edit `/etc/network/interfaces` `bridge-ports` to match `network/interfaces.snippet`.
3. Reboot in a maintenance window (both changes must land together).

Not in the .deb: shipping it active would rename the representors on the next
boot and break the bridge unless the interfaces change lands at the same time.

## Rollback

`apt remove proxmox-mlx5-sriov` (after `systemctl disable` of the instances). To
return a NIC to a clean state: `devlink dev eswitch set pci/<addr> mode legacy`
and `echo 0 > /sys/class/net/<pf>/device/sriov_numvfs`.
