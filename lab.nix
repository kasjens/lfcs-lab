# The lab, as data. Everything else in this repo is derived from this file.
# Change a number here, run `nix run .#lfcs-lab -- apply`, and the libvirt XML
# is regenerated. This is the only file you should normally need to edit.
{
  name = "lfcs";

  # Guest disks and base images live here. Keep it under /var/lib/libvirt so
  # qemu can actually traverse to it — a lab under $HOME is the single most
  # common cause of "Could not open ...: Permission denied" on a system URI.
  stateDir = "/var/lib/libvirt/images/lfcs-lab";

  libvirtUri = "qemu:///system";

  # Console + SSH login. Deliberately weak; this box is disposable and NAT'd.
  user = "lab";
  password = "lfcs";

  networks = {
    # NAT'd management network. This is how you ssh in.
    mgmt = {
      subnet = "192.168.90";
      forward = true;
    };
    # Isolated layer-2 segment with no DHCP and no gateway. Extra NICs land
    # here so bonding, bridging and static addressing have somewhere to happen
    # that cannot break your ssh session.
    lan = {
      forward = false;
    };
  };

  # 8 GB host: node-1 + node-2 = 3.5 GB, leaving the host ~4.5 GB.
  # node-3 is defined but not started by default — bring it up only for the
  # NFS / bonding / reverse-proxy work in week 2 and 3.
  nodes = {
    node-1 = {
      slot = 1;              # -> 192.168.90.11, MAC 52:54:00:1f:c5:1x
      distro = "ubuntu";
      memory = 2048;
      vcpu = 2;
      rootGB = 20;
      extraDisks = 3;        # vdb vdc vdd — PV/VG/LV, mdadm, swap partition
      extraDiskGB = 2;
      lanNics = 2;           # for bonding
      autostart = true;
    };
    node-2 = {
      slot = 2;
      distro = "rocky";      # dnf, firewalld, SELinux enforcing
      memory = 1536;
      vcpu = 2;
      rootGB = 20;
      extraDisks = 3;
      extraDiskGB = 2;
      lanNics = 2;
      autostart = true;
    };
    node-3 = {
      slot = 3;
      distro = "ubuntu";
      memory = 768;
      vcpu = 1;
      rootGB = 12;
      extraDisks = 1;
      extraDiskGB = 2;
      lanNics = 1;
      autostart = false;
    };
  };

  images = {
    ubuntu = {
      url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img";
      file = "ubuntu-noble.qcow2";
    };
    rocky = {
      url = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2";
      file = "rocky-9.qcow2";
    };
  };

  # Packages every node gets, so a drill is never blocked on a missing tool.
  # Man pages are first for a reason: cloud images ship with them stripped.
  packages = {
    ubuntu = [
      "man-db" "manpages" "manpages-dev" "less"
      "lvm2" "mdadm" "xfsprogs" "quota" "acl" "attr" "parted"
      "nfs-kernel-server" "nfs-common" "autofs"
      "nftables" "chrony" "dnsutils" "tcpdump" "iproute2" "net-tools"
      "network-manager" "openssh-server" "rsync" "tree" "jq" "tmux" "vim" "git"
      "podman" "at" "cron" "sysstat"
    ];
    rocky = [
      "man-db" "man-pages" "less"
      "lvm2" "mdadm" "xfsprogs" "quota" "acl" "attr" "parted"
      "nfs-utils" "autofs"
      "firewalld" "chrony" "bind-utils" "tcpdump" "iproute" "net-tools"
      "NetworkManager" "openssh-server" "rsync" "tree" "jq" "tmux" "vim" "git"
      "podman" "at" "cronie" "sysstat" "policycoreutils-python-utils"
    ];
  };
}
