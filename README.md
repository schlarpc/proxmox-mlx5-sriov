# proxmox-mellanox

SR-IOV VF provisioning for the Mellanox ConnectX-6 Dx (`enp33s0f0np0`,
`0000:21:00.0`) on the `proxmox` node. Each VM gets a VF passed through (near
line-rate), while the host keeps vlan-aware switching control over those VFs via
hardware-offloaded eswitch representors bridged into a `vmbr`.

## The one idea that makes this make sense

Proxmox is a thin management layer over stock Debian. It is authoritative only
inside its own domains -- basically everything in `/etc/pve` plus its
ifupdown2-flavored `/etc/network/interfaces`. Everything else (kernel, mlx5,
sysfs, switchdev, systemd units) is plain Debian, with no single blessed path.

Mapping that to this setup:

| Concern                          | Owner            | Mechanism (the "right way")                     |
| -------------------------------- | ---------------- | ----------------------------------------------- |
| VF -> VM attachment              | Proxmox (`/etc/pve`) | PCI resource mapping (`hostpci: mapping=...`) |
| Representor switching / VLANs    | Proxmox ifupdown2 | vlan-aware bridge in `/etc/network/interfaces`  |
| VF creation, switchdev, VF MACs  | **Debian (no native PVE feature)** | the `create-sriov-vfs` oneshot   |
| Resource-mapping registration    | Proxmox API      | `pvesh` in `sync-sriov-vf-mappings`             |

There is no native Proxmox feature for the VF lifecycle, so a script there is
unavoidable, not a smell. We just make it as declarative/ordered as the system
allows.

## Why two units instead of one

The original single script tried to do everything at boot and logged
`ipcc_send_rec ... Connection refused` every time. Root cause: it ran
`Before=network-pre.target` (correct -- the representors must exist before the
bridge comes up), but `pvesh` needs pmxcfs, and `pve-cluster.service` is ordered
`After=network.target`. So the mapping calls fired ~10s before pmxcfs was
mounted. You cannot satisfy both orderings in one unit -- it's a dependency
cycle. Hence the split:

- **sriov-vfs.service** -> `create-sriov-vfs`: switchdev + VFs + per-VF MACs.
  Runs `Before=network-pre.target`. No pve dependency.
- **sriov-vf-mappings.service** -> `sync-sriov-vf-mappings`: `pvesh` mapping
  sync. Runs `After=pve-cluster.service`, `Before=pve-guests.service`.

## Files

```
bin/create-sriov-vfs            VFs + switchdev + deterministic MACs (early)
bin/sync-sriov-vf-mappings      pvesh resource-mapping sync (after pmxcfs)
systemd/sriov-vfs.service       early unit
systemd/sriov-vf-mappings.service   late unit
udev/70-mlx5-vf-representors.rules   OPTIONAL: stable representor names
network/interfaces.snippet      OPTIONAL: matching bridge-ports line
```

## What changed vs the original

- Split into two units so the systemd ordering is actually satisfiable.
- `set -euo pipefail` + per-VF MAC loop fixed (`for ((...))`, no `seq 0 32; break`).
- Single `uevent` read per VF instead of three `cat | grep` pipelines.
- Hardcoded `enp33s0f0np0` in the iommu line replaced with `$DEVICE`.
- Mapping sync is idempotent (update-in-place) instead of delete-all-then-recreate.
- switchdev is **kept** -- the representors are bridged and hw-tc-offloaded, so
  it is load-bearing, not clutter.

## Deploy (maintenance window -- involves a reboot to fully validate)

```bash
install -m755 bin/create-sriov-vfs        /opt/schlarpc/bin/create-sriov-vfs
install -m755 bin/sync-sriov-vf-mappings  /opt/schlarpc/bin/sync-sriov-vf-mappings
install -m644 systemd/sriov-vfs.service          /etc/systemd/system/sriov-vfs.service
install -m644 systemd/sriov-vf-mappings.service  /etc/systemd/system/sriov-vf-mappings.service
systemctl daemon-reload
systemctl enable sriov-vfs.service sriov-vf-mappings.service
systemd-analyze verify sriov-vfs.service sriov-vf-mappings.service   # must be clean
```

The mapping sync can be exercised live without a reboot (it's idempotent):
`systemctl start sriov-vf-mappings.service` then confirm 32 mappings exist.

## Optional: stable representor names

The bridge currently pins `eth0..eth31`, which are unstable kernel names. To
make them hardware-derived (`pf0vf0..pf0vf31`):

1. `install -m644 udev/70-mlx5-vf-representors.rules /etc/udev/rules.d/`
2. Edit `/etc/network/interfaces` `bridge-ports` to match `network/interfaces.snippet`.
3. Reboot in a maintenance window (both changes must land together).

## Rollback

The live deploy backs up the originals next to each file as `*.bak-<epoch>`.
`devlink dev eswitch set pci/0000:21:00.0 mode legacy` + `echo 0 > .../sriov_numvfs`
returns the NIC to a clean state if needed.
