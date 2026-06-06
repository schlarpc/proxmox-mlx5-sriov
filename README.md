# proxmox-mlx5-sriov

SR-IOV VF provisioning for Mellanox ConnectX (mlx5) NICs on Proxmox VE, packaged
as a Debian `.deb` built by a Nix flake. Each VM gets a VF passed through (near
line-rate); the host keeps vlan-aware switching control over those VFs via
hardware-offloaded eswitch representors bridged into a `vmbr`.

PF-agnostic — one systemd template instance per PF. Tested on a ConnectX-6 Dx
(`enp33s0f0np0`, `0000:21:00.0`).

## Scope and assumptions

Shaped around one topology: **switchdev-mode VFs as vlan-aware trunk ports behind
a hardware-offloaded bridge**. Deliberate choices, correct for that and wrong for
others:

- **switchdev mode is forced** — per-VF representors you can bridge and offload.
  Legacy mode (VFs straight on the wire, no representors) is not supported.
- **Every VF is a trunk** — no per-VF VLAN is set; VLAN filtering happens in the
  vlan-aware bridge (full `2-4094` trunk per representor) and the guest tags.
- **VFs keep locked-down defaults** (`spoofchk on`, `trust off`) with a forced
  deterministic admin MAC. No `trust`/`spoofchk`/rate-limit knobs, so guests that
  emit multiple MACs or tag their own VLANs (routers, firewalls, nested virt)
  won't work as-is.
- **The representor bridge is out of scope.** A switchdev VF has no path to the
  wire until its representor is enslaved in a bridge. This package provisions
  VFs/MACs/mappings but does **not** touch `/etc/network/interfaces` — you build
  the vlan-aware bridge yourself.
- **mlx5-only**, and it **re-creates VFs from scratch on every boot** (assumes
  exclusive ownership of the PF's SR-IOV config).

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
VF_MAC_PREFIX="36:7e:3a:0b:0b"
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

## Optional: stable representor names

Kernel representor names (`eth0..eth31`) are unstable. To make them
hardware-derived (`pf0vf0..pf0vf31`):

1. `install -m644 udev/70-mlx5-vf-representors.rules /etc/udev/rules.d/`
2. Edit `/etc/network/interfaces` `bridge-ports` to match `network/interfaces.snippet`.
3. Reboot in a maintenance window (both changes must land together).

Not shipped in the `.deb`: enabling it would rename representors on the next boot
and break the bridge unless the interfaces change lands at the same time.

## Rollback

`apt remove proxmox-mlx5-sriov` (after `systemctl disable` of the instances). To
return a NIC to a clean state:

```bash
devlink dev eswitch set pci/<addr> mode legacy
echo 0 > /sys/class/net/<pf>/device/sriov_numvfs
```
