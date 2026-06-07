# proxmox-mlx5-sriov

SR-IOV VF provisioning for Mellanox ConnectX (mlx5) NICs on Proxmox VE, packaged
as a Debian `.deb` built by a Nix flake. Each VM gets a VF passed through (near
line-rate); the host keeps vlan-aware switching control over those VFs via
hardware-offloaded eswitch representors bridged into a `vmbr`.

PF-agnostic — one systemd template instance per PF. Tested on a ConnectX-6 Dx
(`enp33s0f0np0`, `0000:21:00.0`).

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

Shaped around one topology: **switchdev VFs trunked into a Proxmox vlan-aware
bridge, with the host keeping hardware-offloaded switching control**. The
deliberate choices behind that — worth understanding before you adopt:

- **switchdev is the point, not a limitation.** It gives the *host* a control
  plane over every VF (one representor each) while the NIC's embedded switch does
  the forwarding in hardware — host-side VLAN/bridge/ACL control at line rate,
  dropping straight into Proxmox's vlan-aware bridge model. If you instead just
  want a VF handed to a guest with no host switching (optionally pinned to a VLAN
  via the legacy `ip link set vf vlan` knob), that's **legacy-mode SR-IOV** — a
  simpler, different tool, not this one.
- **Every VF is a dumb trunk pipe; VLAN policy lives on the bridge.** No per-VF
  VLAN is set — each representor joins the vlan-aware bridge as a full `2-4094`
  trunk and the guest tags. To pin a VF to one VLAN, set `bridge-access <vid>` on
  *its representor's* bridge port (not on the VF); mlx5 offloads that filtering
  into the eswitch, so it's hardware-enforced at line rate. The trunk model is
  thus permissive by default: every VF can reach every VLAN until you lock its
  port down.
- **Each VF gets a forced deterministic admin MAC; nothing else is tuned.** The
  package sets the VF MAC and leaves `spoofchk`/`trust`/rate-limits at driver
  defaults — on a current mlx5 switchdev stack both `spoofchk` and `trust` are
  *off* (forwarding and anti-spoof are the eswitch's and the vlan-aware bridge's
  job here, not the legacy per-VF knobs). The practical limit is `trust off`: a
  VF can't go promiscuous or register extra MAC filters, so guests that must
  receive traffic for MACs other than their assigned one (nested virt, MACVLAN,
  some bridging firewalls) need `trust on`, which this doesn't configure.
- **You build the bridge — and not because Proxmox "owns the file."** A switchdev
  VF has no path to the wire until its representor is enslaved in a bridge, yet
  the package doesn't write one. The reason isn't hands-off-Proxmox (it already
  registers PCI mappings through PVE's own API): it automates what it can
  *derive* and apply *non-disruptively* — VFs, stable representor names, mappings.
  The bridge is the opposite. Its management IP, which `vmbr` each VF joins, and
  each port's VLAN policy are un-derivable site decisions, and rewriting the
  bridge that carries the node's management IP is far higher blast-radius than an
  inert mapping. So `interfaces.snippet` is a *starting point* — `bridge-ports`
  only, no IP / VIDs / per-port policy.
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

Kernel representor names (`eth0..eth31`) aren't stable across kernel upgrades or
added NICs, so a renumber can silently drop a representor out of the bridge. The
package ships a udev rule (`/lib/udev/rules.d/70-mlx5-vf-representors.rules`) that
gives them stable names derived from hardware instead.

The mlx5 driver's own `phys_port_name` (`pf0vf0..`) is unique only *within* one
eswitch, so two separate cards both start at `pf0` and collide. The rule prefixes
a short slice of `phys_switch_id` (the per-card eswitch id) via the
`mlx5-sriov-rep-name` helper, producing `sw<tag>pf<port>vf<N>` — e.g.
`swc27cpf0vf31`. That's stable across reboots/kernel upgrades, distinguishes
ports within a card (`pf0`/`pf1`), and stays unique across multiple cards, all
inside the 15-char interface-name limit.

The rename applies on the next boot when the VFs are re-created — never live, so
it can't yank a representor out from under a running bridge. Since the package
doesn't write `/etc/network/interfaces` (see *You build the bridge* above), your
`bridge-ports` line must reference these names. A bundled example is at
`/usr/share/doc/proxmox-mlx5-sriov/examples/interfaces.snippet`; after a reboot,
`ip -d link` shows the actual names the rule produced.

> **Migrating an existing node** whose bridge still pins `eth0..eth31`: switch
> that `bridge-ports` line to the new `sw<tag>pf<port>vfN` names *before* the next
> reboot, or the bridge comes up with no VF ports. The `<tag>` is the last 4 hex
> of `cat /sys/class/net/<pf>/phys_switch_id`, so you can write the names ahead of
> time; on a fresh node, just use them from the start.

## Rollback

`apt remove proxmox-mlx5-sriov` (after `systemctl disable` of the instances). To
return a NIC to a clean state:

```bash
devlink dev eswitch set pci/<addr> mode legacy
echo 0 > /sys/class/net/<pf>/device/sriov_numvfs
```
