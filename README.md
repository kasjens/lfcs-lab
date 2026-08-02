# lfcs-lab

A disposable Linux practice lab for LFCS, declared in Nix and run on libvirt/KVM.

The lab is data. `lab.nix` describes the nodes, disks, networks and packages;
everything else — libvirt domain XML, network XML, cloud-init, and the `lfcs-lab`
command itself — is generated from it. Change a number, run `lfcs-lab apply`.

## Why the guests are not NixOS

NixOS is the worst distribution in the world to practise LFCS on. `/etc` is a
tree of read-only symlinks into the store, `useradd` does not persist, `/etc/fstab`
is generated, and neither `apt` nor `dnf` exists. Every muscle the exam tests is
the one NixOS removes.

So Nix does the host-side job it is actually good at: pinning the toolchain,
generating the XML, and making the whole lab reproducible from one file. The
guests are stock Ubuntu 24.04 and Rocky 9 cloud images — which is what the exam
environment resembles, and the exam is distribution-agnostic, so you want both
families in front of you.

## What you get

| Node | Distro | RAM | Spare disks | Purpose |
|---|---|---|---|---|
| `node-1` | Ubuntu 24.04 | 2048 MB | 3 × 2 GB | `apt`, `nftables`, primary workbench |
| `node-2` | Rocky 9 | 1536 MB | 3 × 2 GB | `dnf`, `firewalld`, SELinux enforcing |
| `node-3` | Ubuntu 24.04 | 768 MB | 1 × 2 GB | second peer for NFS, ssh, routing — **stopped by default** |

On 8 GB that leaves the host about 4.5 GB with node-1 and node-2 running. Start
node-3 only when a drill needs two machines.

Two networks:

- `lfcs-mgmt` — NAT, 192.168.90.0/24, static DHCP leases so `node-1` is always `.11`.
  This is how you ssh in.
- `lfcs-lan` — an isolated layer-2 segment with no gateway and no DHCP. The extra
  NICs land here, so bonding, bridging and static addressing have somewhere to
  happen that **cannot cost you the session you are working from**.

Cloud images ship with documentation stripped. First boot removes
`/etc/dpkg/dpkg.cfg.d/excludes` and `tsflags=nodocs`, then reinstalls the doc
packages and runs `mandb`. A man page drill against a box with no man pages is a
cruel joke.

## Prerequisites

`scripts/bootstrap.sh` resolves all of them and is safe to re-run. It checks
hardware virtualisation, installs the host libvirt/qemu packages, starts the
daemon, fixes group membership, installs Nix if you want it, and writes
`flake.lock`. Nothing mutates without a prompt.

```bash
./scripts/bootstrap.sh --check    # report only
./scripts/bootstrap.sh            # fix, asking before each step
```

By hand it is Nix with flakes, plus libvirt running on the host:

```bash
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER" && newgrp libvirt
```

If the host is NixOS, import the module instead:

```nix
imports = [ inputs.lfcs-lab.nixosModules.host ];
users.users.<you>.extraGroups = [ "libvirtd" "kvm" ];
```

## Use

The first `nix develop` writes a `flake.lock` pinning nixpkgs. Commit it — that
is what makes the toolchain reproducible rather than merely declared.

```bash
nix develop                      # or: nix run .#lfcs-lab -- <cmd>

lfcs-lab install                 # first run: downloads ~1.5 GB, then boots and snapshots
lfcs-lab status
lfcs-lab ssh node-1
lfcs-lab console node-2          # serial console; works when the box will not boot
lfcs-lab reset                   # back to the 'clean' snapshot
```

Read what will be created before you create it:

```bash
nix build .#manifest && find result -type f | xargs -I{} sh -c 'echo "== {}"; cat {}'
```

### Commands

| Command | Does |
|---|---|
| `install` | download images, define networks and domains, first boot, take `clean` |
| `apply` | regenerate libvirt XML from `lab.nix` without touching disks |
| `up` / `down` | start / graceful shutdown, force after two minutes |
| `status` | defined, running, reachable |
| `ssh <node> [cmd]` | shell or one-shot command |
| `console <node>` | serial console, escape with `Ctrl+]` |
| `save <name>` / `load <name>` | snapshot and restore all disks |
| `reset` | `load clean` and start again |
| `break <scenario>` | create a failure to practise recovering from |
| `destroy` | delete every disk, snapshot and definition |

## Breakage drills

`break` only ever creates the symptom. It never tells you the fix, and it never
performs it. `reset` is the way out if you get properly stuck.

| Scenario | Symptom | Skill |
|---|---|---|
| `fstab` | bad UUID in `/etc/fstab`, reboot into the emergency shell | week 1 recovery drill |
| `service` | `chrony` fails to start via a drop-in override | read the journal, find the override |
| `dns` | `resolv.conf` clobbered **and** made immutable | `lsattr` is what people forget |
| `sudoers` | syntax error in `/etc/sudoers.d`, `sudo` refuses everything | root console + `visudo -c` |

```bash
lfcs-lab break fstab node-1
lfcs-lab console node-1     # ssh will not work; that is the point
```

Your plan says do the fstab recovery twice. `reset` between attempts makes the
second one honest.

## Mapping to the study plan

| Week | Domain | Use |
|---|---|---|
| 1 | Operations Deployment | `break fstab`, `break service`, `break sudoers`; sysctl persistence across `reset` |
| 2 | Networking | `lfcs-lan` NICs for bonding and bridging; node-2's `firewalld` vs node-1's `nftables` |
| 3 | Storage | the three spare disks: PV → VG → LV → filesystem → fstab → grow it online |
| 4 | Users and Groups | `chage`, ACLs, `limits.conf`; `reset` between attempts |

## Snapshots

`save` and `load` copy the qcow2 files with `--reflink=auto`, so on btrfs or XFS
they are near-instant and near-free. The root disks are thin overlays on a shared
base image, so a whole lab snapshot is tens of megabytes, not gigabytes.

The lab is shut down before a snapshot is taken. A live copy of a running qcow2
is not crash-consistent and would eventually hand you a corrupted filesystem you
did not create — which is a bad way to learn `fsck`.

## The one non-reproducible part

Base image URLs point at `current` / `latest`, so the exact bytes you get depend
on when you run `install`. That is deliberate: pinning a hash means the URL 404s
the next time upstream rebuilds. If you want it fully pinned, swap the runtime
`curl` for `pkgs.fetchurl` with a dated release URL:

```
https://cloud-images.ubuntu.com/releases/noble/release-20260401/noble-server-cloudimg-amd64.img
```

## Passwords

`lab.nix` sets both `lab` and `root` to `lfcs`, and `sudo` is `NOPASSWD`. This is
a NAT'd disposable lab with no port forwards, and you need a console password for
the emergency-shell drills to work at all. Do not reuse the pattern anywhere else.
