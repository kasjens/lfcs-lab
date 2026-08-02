#!/usr/bin/env bash
# Resolve everything lfcs-lab needs before the first `lfcs-lab install`.
#
# Two layers of dependency:
#   host   libvirtd, qemu/KVM, dnsmasq — these must live on the host, because
#          the system libvirt daemon is what actually spawns the guests
#   nix    the client toolchain and the generated XML, pinned by flake.lock
#
# Everything here is idempotent: run it again after a reboot, a distro upgrade,
# or a topology change and it will only do what is still missing.
#
#   ./scripts/bootstrap.sh            check, then fix with a prompt per step
#   ./scripts/bootstrap.sh --check    report only, change nothing
#   ./scripts/bootstrap.sh -y         assume yes, for unattended runs
#   ./scripts/bootstrap.sh --no-nix   skip installing Nix (still locks if present)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX_INSTALLER="https://nixos.org/nix/install"

ASSUME_YES=0
CHECK_ONLY=0
WANT_NIX=1
PROBLEMS=0
RELOGIN=0

log()  { printf '\033[36m::\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32mok\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

miss() { printf '\033[31m--\033[0m %s\n' "$*" >&2; PROBLEMS=$((PROBLEMS + 1)); }

# Ask, unless -y. In --check mode the answer is always no: nothing mutates.
confirm() {
  if [ "$CHECK_ONLY" = 1 ]; then return 1; fi
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  local answer
  read -r -p "   $1 [Y/n] " answer </dev/tty || return 1
  case "$answer" in n | N | no | NO) return 1 ;; *) return 0 ;; esac
}

SUDO=""
need_sudo() {
  if [ "$(id -u)" = 0 ]; then return 0; fi
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; return 0; fi
  die "not root and no sudo — install the host packages by hand"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y | --yes) ASSUME_YES=1 ;;
    -n | --check | --dry-run) CHECK_ONLY=1 ;;
    --no-nix) WANT_NIX=0 ;;
    -h | --help)
      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# 1. Can this host run the lab at all
# --------------------------------------------------------------------------

check_hardware() {
  log "hardware"

  # The flake builds for x86_64-linux only, and the cloud image URLs in lab.nix
  # are amd64. An aarch64 lab needs different images and machine='virt'.
  local arch; arch="$(uname -m)"
  if [ "$arch" != "x86_64" ]; then
    miss "architecture is $arch; the flake and lab.nix images are x86_64 only"
  else
    ok "architecture x86_64"
  fi

  if grep -qE '^flags.*\b(vmx|svm)\b' /proc/cpuinfo; then
    ok "CPU virtualisation extensions present"
  elif grep -qE '^flags.*\bsvm_lock\b' /proc/cpuinfo; then
    # svm_lock without svm is the specific, common signature of an AMD box
    # whose firmware has SVM switched off. kvm_amd will refuse to load.
    miss "AMD-V is present but locked off in firmware — enable SVM in the BIOS (no other fix works)"
  else
    miss "no vmx/svm in /proc/cpuinfo — enable VT-x/AMD-V in firmware, or guests crawl under emulation"
  fi

  local mem_gb; mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  if [ "$mem_gb" -lt 6 ]; then
    warn "${mem_gb} GB RAM — node-1 + node-2 want 3.5 GB. Trim memory in lab.nix."
  else
    ok "${mem_gb} GB RAM"
  fi

  # Base images ~1.5 GB, plus thin overlays and one snapshot set.
  local free_gb; free_gb=$(df -BG --output=avail /var/lib 2>/dev/null | tail -n1 | tr -dc '0-9')
  if [ -n "$free_gb" ] && [ "$free_gb" -lt 15 ]; then
    warn "${free_gb} GB free on /var/lib — images and snapshots want ~15 GB"
  elif [ -n "$free_gb" ]; then
    ok "${free_gb} GB free on /var/lib"
  fi
}

# --------------------------------------------------------------------------
# 2. Host packages: the libvirt daemon and qemu that actually run the guests
# --------------------------------------------------------------------------

PKG_MGR=""
detect_pkg_mgr() {
  local m
  for m in apt-get dnf pacman zypper; do
    if command -v "$m" >/dev/null 2>&1; then PKG_MGR="$m"; return 0; fi
  done
  return 1
}

host_packages() {
  case "$PKG_MGR" in
    apt-get) echo "qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients dnsmasq-base" ;;
    dnf)     echo "qemu-kvm libvirt libvirt-client libvirt-daemon-config-network dnsmasq" ;;
    pacman)  echo "qemu-full libvirt dnsmasq iptables-nft" ;;
    zypper)  echo "qemu-kvm libvirt libvirt-client dnsmasq" ;;
  esac
}

pkg_installed() {
  case "$PKG_MGR" in
    apt-get) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "^install ok installed" ;;
    dnf | zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Qi "$1" >/dev/null 2>&1 ;;
  esac
}

install_packages() {
  local pkgs=("$@")
  need_sudo
  case "$PKG_MGR" in
    apt-get) $SUDO apt-get update -qq && $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ;;
    dnf)     $SUDO dnf install -y "${pkgs[@]}" ;;
    pacman)  $SUDO pacman -S --needed --noconfirm "${pkgs[@]}" ;;
    zypper)  $SUDO zypper --non-interactive install "${pkgs[@]}" ;;
  esac
}

check_host_packages() {
  log "host virtualisation packages"

  if ! detect_pkg_mgr; then
    if [ -e /etc/NIXOS ]; then
      warn "NixOS host — do not use this script for the host side."
      warn "Import the module instead: imports = [ inputs.lfcs-lab.nixosModules.host ];"
      return 0
    fi
    miss "no apt/dnf/pacman/zypper found — install libvirt, qemu-kvm and dnsmasq by hand"
    return 0
  fi

  local missing=() p
  for p in $(host_packages); do
    if pkg_installed "$p"; then ok "$p"; else missing+=("$p"); fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then return 0; fi

  miss "missing: ${missing[*]}"
  if confirm "install them with $PKG_MGR?"; then
    install_packages "${missing[@]}"
    PROBLEMS=$((PROBLEMS - 1))
    ok "installed ${missing[*]}"
  fi
}

# --------------------------------------------------------------------------
# 3. The daemon, /dev/kvm, and group membership
# --------------------------------------------------------------------------

start_unit() {
  need_sudo
  # Modern distros may ship modular daemons instead of the monolithic libvirtd.
  if systemctl list-unit-files libvirtd.service >/dev/null 2>&1 &&
     $SUDO systemctl enable --now libvirtd.service 2>/dev/null; then
    return 0
  fi
  $SUDO systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket
}

check_daemon() {
  log "libvirtd"

  if ! command -v systemctl >/dev/null 2>&1; then
    miss "no systemd here — start libvirtd however this host does it"
    return 0
  fi

  if systemctl is-active --quiet libvirtd.service 2>/dev/null ||
     systemctl is-active --quiet virtqemud.service 2>/dev/null ||
     systemctl is-active --quiet virtqemud.socket 2>/dev/null; then
    ok "libvirt daemon running"
  else
    miss "libvirt daemon is not running"
    if confirm "enable and start it now?"; then
      start_unit
      PROBLEMS=$((PROBLEMS - 1))
      ok "libvirt daemon started"
    fi
  fi
}

check_groups() {
  log "permissions"

  if [ -e /dev/kvm ]; then
    if [ -w /dev/kvm ]; then ok "/dev/kvm writable"; else warn "/dev/kvm exists but is not writable by you"; fi
  else
    miss "/dev/kvm absent — the kvm module is not loaded, or virtualisation is off in firmware"
  fi

  local g want=() have; have="$(id -nG)"
  for g in libvirt kvm; do
    if getent group "$g" >/dev/null 2>&1 && ! printf ' %s ' "$have" | grep -q " $g "; then
      want+=("$g")
    fi
  done

  if [ "${#want[@]}" -eq 0 ]; then
    ok "group membership: libvirt, kvm"
    return 0
  fi

  miss "not in group(s): ${want[*]}"
  if confirm "add $USER to ${want[*]}?"; then
    need_sudo
    for g in "${want[@]}"; do $SUDO usermod -aG "$g" "$USER"; done
    PROBLEMS=$((PROBLEMS - 1))
    RELOGIN=1
    ok "added to ${want[*]} — takes effect on your next login"
  fi
}

# --------------------------------------------------------------------------
# 4. Nix, flakes, and the lock file
# --------------------------------------------------------------------------

load_nix_profile() {
  local f
  for f in /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
           "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
    # shellcheck disable=SC1090
    if [ -f "$f" ]; then set +u; . "$f"; set -u; fi
  done
}

# `nix flake --version` is not a test: --version is handled before the
# experimental-feature gate, so it exits 0 on a Nix that has flakes disabled.
# Probe the features by using them instead.
flakes_enabled() {
  nix eval --expr 1 --impure >/dev/null 2>&1 || return 1   # nix-command
  { nix config show experimental-features 2>/dev/null ||
    nix show-config 2>/dev/null | grep '^experimental-features'; } | grep -qw flakes
}

check_nix() {
  log "nix"

  if ! command -v nix >/dev/null 2>&1; then load_nix_profile; fi

  if ! command -v nix >/dev/null 2>&1; then
    miss "nix is not installed"
    if [ "$WANT_NIX" = 0 ]; then
      warn "skipping (--no-nix)"
      return 1
    fi
    warn "the next step downloads and runs the official installer:"
    warn "  sh <(curl -L $NIX_INSTALLER) --daemon"
    if ! confirm "run it?"; then
      warn "skipped. Install Nix yourself, then re-run this script."
      return 1
    fi
    sh <(curl -L "$NIX_INSTALLER") --daemon
    load_nix_profile
    command -v nix >/dev/null 2>&1 || {
      warn "nix installed, but not on PATH in this shell. Open a new shell and re-run."
      return 1
    }
    PROBLEMS=$((PROBLEMS - 1))
  fi
  ok "nix $(nix --version | awk '{print $3}')"

  # flake.nix is useless without the experimental features that read it.
  if flakes_enabled; then
    ok "flakes enabled"
    return 0
  fi

  miss "flakes are not enabled"
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
  if ! confirm "add 'experimental-features = nix-command flakes' to $conf?"; then
    return 1
  fi

  mkdir -p "$(dirname "$conf")"
  printf 'experimental-features = nix-command flakes\n' >>"$conf"

  # Earn the ok: nix re-reads its config on every invocation, so the same
  # probe that just failed should now pass.
  if ! flakes_enabled; then
    warn "wrote $conf but the features are still off — something else is overriding it:"
    warn "  nix config show experimental-features"
    return 1
  fi
  PROBLEMS=$((PROBLEMS - 1))
  ok "wrote $conf"
}

check_lock() {
  local have_nix="$1"
  log "toolchain lock"

  if [ -f "$REPO/flake.lock" ]; then
    ok "flake.lock present"
  else
    miss "flake.lock absent — the toolchain is declared but not pinned"
    if [ "$have_nix" != 0 ]; then
      warn "needs a working nix; resolve the nix items above first"
      return 0
    fi
    if confirm "generate it now (nix flake lock)?"; then
      nix flake lock "$REPO"
      PROBLEMS=$((PROBLEMS - 1))
      ok "flake.lock written — commit it, that is what makes this reproducible"
    else
      return 0
    fi
  fi

  # Realise the CLI and the generated XML now, so the first `lfcs-lab install`
  # is only waiting on the image download and not on a nixpkgs build.
  if [ "$have_nix" = 0 ] && confirm "pre-build the lfcs-lab CLI and manifest (a few minutes, once)?"; then
    nix build "$REPO#lfcs-lab" "$REPO#manifest" --no-link
    ok "toolchain realised"
  fi
}

# --------------------------------------------------------------------------

check_hardware
check_host_packages
check_daemon
check_groups
have_nix=0
check_nix || have_nix=1
check_lock "$have_nix"

echo >&2
if [ "$CHECK_ONLY" = 1 ]; then
  if [ "$PROBLEMS" -gt 0 ]; then
    warn "$PROBLEMS unresolved item(s). Re-run without --check to fix them."
    exit 1
  fi
  ok "everything the lab needs is already in place"
  exit 0
fi

if [ "$PROBLEMS" -gt 0 ]; then
  warn "$PROBLEMS item(s) still unresolved — see the -- lines above"
  exit 1
fi

if [ "$RELOGIN" = 1 ]; then
  warn "group changes need a new login. Either log out and back in, or:"
  warn "  newgrp libvirt"
fi

cat >&2 <<EOF

Dependencies resolved. Next:

  nix develop            enter the shell with lfcs-lab in scope
  lfcs-lab install       download images, define the lab, first boot, snapshot

Read what will be created before creating it:

  nix build .#manifest && find result -type f | xargs -I{} sh -c 'echo "== {}"; cat {}'
EOF
