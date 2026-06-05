# proxmox-mellanox

SR-IOV VF provisioning for the Mellanox ConnectX-6 Dx (`enp33s0f0np0`,
`0000:21:00.0`) on the `proxmox` node, packaged as a Debian `.deb` that is built
by a Nix flake. Each VM gets a VF passed through (near line-rate), while the
host keeps vlan-aware switching control over those VFs via hardware-offloaded
eswitch representors bridged into a `vmbr`.

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

There is no native Proxmox feature for the VF lifecycle, so a script there is
unavoidable, not a smell. We just make it declarative/ordered and ship it as a
proper package.

## Why two units instead of one

The original single script tried to do everything at boot and logged
`ipcc_send_rec ... Connection refused` every time. Root cause: it ran
`Before=network-pre.target` (correct -- the representors must exist before the
bridge comes up), but `pvesh` needs pmxcfs, and `pve-cluster.service` is ordered
`After=network.target`. You cannot satisfy both orderings in one unit -- it's a
dependency cycle. Hence the split:

- **sriov-vfs.service** -> `create-sriov-vfs`: switchdev + VFs + per-VF MACs.
  Runs `Before=network-pre.target`. No pve dependency.
- **sriov-vf-mappings.service** -> `sync-sriov-vf-mappings`: `pvesh` mapping
  sync. Runs `After=pve-cluster.service`, `Before=pve-guests.service`.

## Layout

```
flake.nix                       Nix flake; `nix build .#deb`
package.nix                     derivation that drives dpkg-deb
bin/create-sriov-vfs            VFs + switchdev + deterministic MACs (early)
bin/sync-sriov-vf-mappings      pvesh resource-mapping sync (after pmxcfs)
etc/default/sriov-vfs           config (dpkg conffile)
systemd/sriov-vfs.service       early unit
systemd/sriov-vf-mappings.service   late unit
debian/                         control, conffiles, postinst/prerm/postrm
udev/70-mlx5-vf-representors.rules   OPTIONAL: stable representor names (not packaged)
network/interfaces.snippet      OPTIONAL: matching bridge-ports line
```

## Configuration

Host config lives in `/etc/default/sriov-vfs` (a dpkg conffile, so your edits
survive upgrades). Both scripts source it. Only one value is required:

| Variable        | Required | Default if unset                                            |
| --------------- | -------- | ----------------------------------------------------------- |
| `PF_INTERFACE`  | yes      | --  (the PF's PCI address is derived from it)                |
| `VF_COUNT`      | no       | `min(32, sriov_totalvfs)`; validated against the hw ceiling |
| `VF_MAC_PREFIX` | no       | locally-administered prefix hashed from the PF permanent MAC |

The derived `VF_MAC_PREFIX` is stable per host and unique across hosts (the full
PF MAC is hashed, so cards with sequential factory MACs don't collide on the
prefix) -- which is what makes the package's default safe to install on multiple
nodes unedited. Set it explicitly if you coordinate MACs with DHCP reservations
or switch port-security. `create-sriov-vfs` logs the values it ends up using.

## Build the .deb

```bash
nix build .#deb
ls -l result/        # -> result/sriov-vfs_<version>_all.deb
```

The build is hermetic and reproducible: `dpkg-deb` runs inside the derivation,
ownership is forced to `root:root` (`--root-owner-group`, no fakeroot), and
`SOURCE_DATE_EPOCH` (set by stdenv) clamps timestamps so the output is
bit-for-bit identical across machines. `nix build .#deb --rebuild` verifies this.
The package is `Architecture: all`, so the same artifact is produced on any
build host. `nix develop` drops you into a shell with `dpkg` + `shellcheck`.

## Install on the node

```bash
scp result/sriov-vfs_*_all.deb root@proxmox:/tmp/
ssh root@proxmox 'apt install -y /tmp/sriov-vfs_*_all.deb'   # or: dpkg -i
```

postinst enables both units but **does not start them** -- they are boot-time
provisioning units, and re-running VF creation under live guests is undesirable.
They take effect on the next reboot. To validate the mapping half without
rebooting: `systemctl start sriov-vf-mappings.service` (idempotent), then check
that 32 mappings exist.

> Note: installing this over a host where the scripts/units were placed by hand
> in `/opt/schlarpc/bin` and `/etc/systemd/system` will leave the hand-placed
> `/etc/systemd/system/*.service` shadowing the package copies in
> `/lib/systemd/system`. Remove the hand-placed unit files first so the package
> becomes the single source of truth.

## Optional: stable representor names

The bridge currently pins `eth0..eth31`, which are unstable kernel names. To make
them hardware-derived (`pf0vf0..pf0vf31`):

1. `install -m644 udev/70-mlx5-vf-representors.rules /etc/udev/rules.d/`
2. Edit `/etc/network/interfaces` `bridge-ports` to match `network/interfaces.snippet`.
3. Reboot in a maintenance window (both changes must land together).

This is intentionally **not** in the .deb: shipping it active would rename the
representors on the next boot and break the bridge unless the interfaces change
lands at the same time.

## Rollback

`apt remove sriov-vfs` (or `dpkg -r sriov-vfs`) disables the units; `--purge`
also removes the conffile. To return the NIC to a clean state:
`devlink dev eswitch set pci/0000:21:00.0 mode legacy` and
`echo 0 > /sys/class/net/enp33s0f0np0/device/sriov_numvfs`.
