# proxmox-mlx5-sriov

SR-IOV VF provisioning for Mellanox ConnectX (mlx5) NICs on Proxmox VE, packaged
as a Debian `.deb` built by a Nix flake. Each VM gets a VF passed through (near
line-rate); the host keeps vlan-aware switching control over those VFs via
hardware-offloaded eswitch representors bridged into a `vmbr`.

PF-agnostic — one systemd template instance per PF. Tested on ConnectX-6 Dx.

## Prerequisites

- **Proxmox VE 8.0+.** The mapping sync uses the `/cluster/mapping/pci` API and
  `hostpci: mapping=`, both introduced in PVE 8.0 (enforced via the package
  dependency on `pve-manager (>= 8.0.0)`).
- **IOMMU enabled.** PCI passthrough — and a usable resource mapping — needs the
  IOMMU on: `intel_iommu=on` (or `amd_iommu=on`) plus `iommu=pt` on the kernel
  command line, then reboot. `mlx5-sriov-sync-mappings` refuses to run without a
  VF IOMMU group rather than registering an unusable mapping.
- **A switchdev-capable mlx5 NIC** (ConnectX-4 or newer).

## Scope and assumptions

Built for one topology: **switchdev VFs trunked into a Proxmox vlan-aware bridge,
the host keeping hardware-offloaded switching control.** What that commits you to:

- **switchdev, by design.** Each VF gets a host-side representor while the NIC's
  eswitch forwards in hardware — host VLAN/bridge/ACL control at line rate, native
  to Proxmox's bridge model. If you just want a VF on the wire (optionally on one
  VLAN via `ip link set vf vlan`), use **legacy-mode SR-IOV** — a different,
  simpler tool, not this one.
- **Every VF is a trunk; VLAN policy lives on the bridge.** No per-VF VLAN is set —
  each representor is a full `2-4094` trunk and the guest tags. Pin one to a VLAN
  with `bridge-access` on its representor port (see below). Permissive by default:
  every VF reaches every VLAN until you lock its port.
- **Forced admin MAC; nothing else tuned.** The package sets each VF's MAC and
  leaves `spoofchk`/`trust`/rate-limits at driver defaults (both *off* on current
  mlx5 switchdev — enforcement is the bridge/eswitch, not legacy per-VF knobs).
  The catch: with `trust off` a VF can't go promiscuous or add MAC filters, so
  multi-MAC guests (nested virt, MACVLAN) would need `trust on`, which is unset.
- **You build the bridge.** The package automates what it can derive and apply
  safely — VFs, stable names, mappings (via PVE's API) — but not
  `/etc/network/interfaces`: the bridge's IP, target `vmbr`, and per-port VLANs are
  site policy, and reloading the management bridge is high blast-radius. The
  bundled `interfaces.snippet` is a `bridge-ports` starting point, nothing more.
- **mlx5-only**, and it **re-creates VFs every boot** (assumes exclusive ownership
  of the PF's SR-IOV config).

## How it works

Two template units per PF, because the two halves have incompatible ordering
needs that can't live in one unit:

- **`mlx5-sriov-vfs@<pf>.service`** → `mlx5-sriov-create-vfs <pf>`: switchdev +
  VFs + per-VF MACs. Runs `Before=network-pre.target` (representors must exist
  before the bridge comes up). No PVE dependency.
- **`mlx5-sriov-mappings@<pf>.service`** → `mlx5-sriov-sync-mappings <pf>`: the
  `pvesh` resource-mapping sync. Needs pmxcfs, so it runs `After=pve-cluster.service`
  (itself `After=network.target`) and `Before=pve-guests.service`.

You enable only the VFs unit; it `Wants=` the mapping instance, which is pulled in
and still runs at its own late ordering. One PF = one `systemctl enable`. Multiple
PFs = multiple independent instances (per-PF mapping IDs and MAC prefixes never
collide).

## Configuration (optional)

No required config file — everything is inferred:

| Input           | Source                                                          |
| --------------- | --------------------------------------------------------------- |
| PF interface    | the systemd instance name (`%i`)                                |
| PF PCI address  | derived from the interface                                      |
| `VF_COUNT`      | `min(32, sriov_totalvfs)`                                       |
| `VF_MAC_PREFIX` | locally-administered prefix hashed from the PF's permanent MAC  |

Override the last two per-PF by dropping a shell snippet at
`/etc/default/mlx5-sriov.d/<interface>` (sourced if present):

```sh
# /etc/default/mlx5-sriov.d/enp33s0f0np0
VF_COUNT="16"
VF_MAC_PREFIX="02:00:00:ab:cd"
```

Pin `VF_MAC_PREFIX` only if you coordinate MACs with DHCP reservations or switch
port-security; the derived one is stable per host and unique across hosts.

## Build

```bash
nix build .#deb
ls result/        # -> proxmox-mlx5-sriov_<version>_all.deb
```

Hermetic and reproducible: `dpkg-deb` runs in the derivation, ownership forced to
`root:root`, and `SOURCE_DATE_EPOCH` clamps timestamps so output is bit-for-bit
identical (`nix build .#deb --rebuild` verifies). `Architecture: all`.
`nix develop` gives a shell with `dpkg` + `shellcheck`.

## Releases

Every push to `main` (and manual `workflow_dispatch`) runs
`.github/workflows/release.yml`: it installs Nix via the Determinate Systems
[`nix-installer-action`](https://github.com/DeterminateSystems/nix-installer-action),
builds the `.deb`, and uploads it to a GitHub Release tagged `build-<shortsha>`.
Re-running on the same commit refreshes the asset; no secrets needed (built-in
`GITHUB_TOKEN`, `contents: write`).

The version is derived from the commit in `flake.nix`:
`1.0.0+<commitdate>.g<shortrev>` (e.g. `…_1.0.0+20260606093355.gdeadbee_all.deb`).
The date leads so `dpkg`/`apt` ordering stays monotonic — a bare hash sorts
arbitrarily and `apt` would treat half of all upgrades as downgrades. Bump
`baseVersion` in `flake.nix` to move off `1.0.0`.

## Install

```bash
scp result/proxmox-mlx5-sriov_*_all.deb root@proxmox:/tmp/
ssh root@proxmox 'apt install -y /tmp/proxmox-mlx5-sriov_*_all.deb'
```

Nothing auto-enables (template units have no implicit instance). Enable one unit
per PF — the mapping sync comes along automatically:

```bash
systemctl enable mlx5-sriov-vfs@enp33s0f0np0.service
```

These are boot-time provisioning units; let them run on the next reboot rather
than under live guests. To validate the mapping half without rebooting once VFs
exist: `systemctl start mlx5-sriov-mappings@<pf>` (idempotent), then check the
mappings.

## Representor names

Kernel names (`eth0..eth31`) aren't stable across kernel upgrades or added NICs, so
a renumber can silently drop a representor from the bridge. The package ships a
udev rule (`/lib/udev/rules.d/70-mlx5-vf-representors.rules`) that names them from
hardware instead: `sw<tag>pf<port>vf<N>` (e.g. `sw1234pf0vf31`), where `<tag>` is a
slice of `phys_switch_id`. Stable, distinguishes ports within a card (`pf0`/`pf1`),
and unique across cards — `phys_port_name` alone (`pf0vfN`) collides because every
card restarts at `pf0`.

The rename lands on the next boot when VFs are re-created, never live. Your
`bridge-ports` must reference these names (`ip -d link` shows them post-reboot;
example in `/usr/share/doc/proxmox-mlx5-sriov/examples/interfaces.snippet`).

> **Migrating** a node whose bridge still pins `eth0..eth31`: switch that line to
> the new names *before* rebooting (`<tag>` is the last 4 hex of
> `/sys/class/net/<pf>/phys_switch_id`), or the bridge comes up with no VF ports.

## Locking a VF to a VLAN

Pinning a VF to one access VLAN is a change to its **representor's bridge port**,
not the VF — and there's **no Proxmox GUI field** for it (the per-VM "VLAN Tag" is
virtio/tap-only). So it's an `/etc/network/interfaces` edit + `ifreload -a`:

```sh
iface sw1234pf0vf16
    bridge-access 2070
```

Put it on the representor's stanza in the main file (PVE round-trips options it
doesn't model, so the GUI won't clobber it), or in an `/etc/network/interfaces.d/`
overlay — `interfaces(5)` merges multiple stanzas for one device, so the overlay
applies on top of PVE's base stanza and removing it restores the trunk. The
eswitch enforces the filtering in hardware.

## Rollback

`apt remove proxmox-mlx5-sriov` (after `systemctl disable` of the instances). To
return a NIC to a clean state:

```bash
devlink dev eswitch set pci/<addr> mode legacy
echo 0 > /sys/class/net/<pf>/device/sriov_numvfs
```
