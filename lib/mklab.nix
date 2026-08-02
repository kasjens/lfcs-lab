{ pkgs, topology }:

let
  lib = pkgs.lib;
  t = topology;

  nodeNames = lib.attrNames t.nodes;
  autoNodes = lib.filter (n: t.nodes.${n}.autostart) nodeNames;

  netName = k: "${t.name}-${k}";
  mgmt = t.networks.mgmt;

  # MAC layout: 52:54:00:1f:c5:<slot><nic>. nic 0 is management, 1..n are the
  # isolated segment. Slots stay single-digit so every byte is valid hex.
  macOf = node: nic: "52:54:00:1f:c5:${toString node.slot}${toString nic}";
  ipOf = node: "${mgmt.subnet}.${toString (10 + node.slot)}";

  letters = [ "b" "c" "d" "e" "f" "g" ];

  # Deterministic UUIDs, derived from the object's name. Without a <uuid> in
  # the XML libvirt invents a random one at define time, and every later
  # define then fails with "already exists with uuid ..." — which would make
  # `apply` a command you can only ever run once. Same name, same UUID, so
  # redefining is an update rather than a collision.
  mkUuid = s:
    let
      h = builtins.hashString "sha256" "${t.name}/${s}";
      f = off: len: lib.substring off len h;
    in
    # version nibble 4, variant nibble a: shaped like a v4 UUID, but stable.
    "${f 0 8}-${f 8 4}-4${f 13 3}-a${f 17 3}-${f 20 12}";

  ##########################################################################
  # Networks
  ##########################################################################

  mgmtNet = pkgs.writeText "${netName "mgmt"}.xml" ''
    <network>
      <name>${netName "mgmt"}</name>
      <uuid>${mkUuid (netName "mgmt")}</uuid>
      <forward mode='nat'/>
      <bridge name='vbr-${t.name}m' stp='on' delay='0'/>
      <ip address='${mgmt.subnet}.1' netmask='255.255.255.0'>
        <dhcp>
          <range start='${mgmt.subnet}.100' end='${mgmt.subnet}.200'/>
    ${lib.concatMapStringsSep "\n" (n:
      let node = t.nodes.${n}; in
      "      <host mac='${macOf node 0}' name='${n}' ip='${ipOf node}'/>")
      nodeNames}
        </dhcp>
      </ip>
    </network>
  '';

  # No <forward>, no <ip>: a pure layer-2 segment. Nothing you do here can
  # cost you the ssh session you are working from.
  lanNet = pkgs.writeText "${netName "lan"}.xml" ''
    <network>
      <name>${netName "lan"}</name>
      <uuid>${mkUuid (netName "lan")}</uuid>
      <bridge name='vbr-${t.name}l' stp='on' delay='0'/>
    </network>
  '';

  ##########################################################################
  # Domains
  ##########################################################################

  diskXml = node: name:
    let
      extra = lib.genList (i: ''
        <disk type='file' device='disk'>
              <driver name='qemu' type='qcow2' discard='unmap'/>
              <source file='${t.stateDir}/disks/${name}-vd${lib.elemAt letters i}.qcow2'/>
              <target dev='vd${lib.elemAt letters i}' bus='virtio'/>
            </disk>'') node.extraDisks;
    in ''
      <disk type='file' device='disk'>
              <driver name='qemu' type='qcow2' discard='unmap'/>
              <source file='${t.stateDir}/disks/${name}-root.qcow2'/>
              <target dev='vda' bus='virtio'/>
            </disk>
            ${lib.concatStringsSep "\n        " extra}
            <disk type='file' device='cdrom'>
              <driver name='qemu' type='raw'/>
              <source file='${t.stateDir}/seed/${name}-seed.iso'/>
              <target dev='sda' bus='sata'/>
              <readonly/>
            </disk>'';

  nicXml = node:
    let
      lanNics = lib.genList (i: ''
        <interface type='network'>
              <source network='${netName "lan"}'/>
              <mac address='${macOf node (i + 1)}'/>
              <model type='virtio'/>
            </interface>'') node.lanNics;
    in ''
      <interface type='network'>
              <source network='${netName "mgmt"}'/>
              <mac address='${macOf node 0}'/>
              <model type='virtio'/>
            </interface>
            ${lib.concatStringsSep "\n        " lanNics}'';

  domainXml = name: node: pkgs.writeText "${t.name}-${name}.xml" ''
    <domain type='kvm'>
      <name>${t.name}-${name}</name>
      <uuid>${mkUuid "${t.name}-${name}"}</uuid>
      <title>LFCS lab: ${name} (${node.distro})</title>
      <memory unit='MiB'>${toString node.memory}</memory>
      <currentMemory unit='MiB'>${toString node.memory}</currentMemory>
      <vcpu placement='static'>${toString node.vcpu}</vcpu>
      <os>
        <type arch='x86_64' machine='q35'>hvm</type>
        <boot dev='hd'/>
      </os>
      <features>
        <acpi/>
        <apic/>
      </features>
      <cpu mode='host-passthrough' check='none'/>
      <clock offset='utc'>
        <timer name='rtc' tickpolicy='catchup'/>
        <timer name='pit' tickpolicy='delay'/>
        <timer name='hpet' present='no'/>
      </clock>
      <on_poweroff>destroy</on_poweroff>
      <on_reboot>restart</on_reboot>
      <on_crash>destroy</on_crash>
      <pm>
        <suspend-to-mem enabled='no'/>
        <suspend-to-disk enabled='no'/>
      </pm>
      <devices>
        ${diskXml node name}
        ${nicXml node}
        <controller type='usb' model='none'/>
        <serial type='pty'>
          <target type='isa-serial' port='0'>
            <model name='isa-serial'/>
          </target>
        </serial>
        <console type='pty'>
          <target type='serial' port='0'/>
        </console>
        <channel type='unix'>
          <target type='virtio' name='org.qemu.guest_agent.0'/>
        </channel>
        <memballoon model='virtio'/>
        <rng model='virtio'>
          <backend model='random'>/dev/urandom</backend>
        </rng>
        <!-- A VGA adapter with no <graphics> to display it: the guests stay
             headless and serial-only, but the hardware exists. Rocky's GRUB
             hangs forever after "Probing EDD (edd=off to disable)... ok" on a
             machine with no video device at all, which looks exactly like a
             dead VM — no console output, no DHCP, 100% CPU. Ubuntu's GRUB is
             built with a serial terminal and does not care. Two lines here
             are cheaper than that afternoon. It also makes `virsh screenshot`
             work, which is the only way to see a bootloader that never
             reaches the serial console. -->
        <video>
          <model type='vga' vram='16384' heads='1' primary='yes'/>
        </video>
      </devices>
    </domain>
  '';

  ##########################################################################
  # cloud-init
  ##########################################################################

  hostsFile = ''
    127.0.0.1 localhost
    ::1 localhost ip6-localhost ip6-loopback
  '' + lib.concatMapStringsSep "\n"
    (n: "${ipOf t.nodes.${n}} ${n} ${n}.lab.local") nodeNames;

  indent = n: s:
    lib.concatMapStringsSep "\n"
      (l: lib.fixedWidthString n " " "" + l)
      (lib.splitString "\n" s);

  # Cloud images ship with documentation stripped. A man page drill against a
  # box with no man pages is a cruel joke, so undo it on first boot.
  distroBits = {
    ubuntu = {
      adminGroup = "sudo";
      preflight = [
        "rm -f /etc/dpkg/dpkg.cfg.d/excludes"
      ];
      postflight = [
        "systemctl disable --now systemd-networkd-wait-online.service || true"
        "DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall man-db manpages manpages-dev coreutils util-linux passwd login mount cron"
        "mandb -q || true"
      ];
    };
    rocky = {
      adminGroup = "wheel";
      preflight = [
        "sed -i '/^tsflags=nodocs/d' /etc/dnf/dnf.conf"
      ];
      postflight = [
        "systemctl disable --now NetworkManager-wait-online.service || true"
        "dnf -y reinstall man-db man-pages coreutils util-linux shadow-utils util-linux-core || true"
        "mandb -q || true"
      ];
    };
  };

  userData = name: node:
    let
      d = distroBits.${node.distro};
      pkgList = t.packages.${node.distro};
      yamlList = xs: lib.concatMapStringsSep "\n" (x: "  - ${x}") xs;
      cmdList = xs: lib.concatMapStringsSep "\n" (x: "  - ${x}") xs;
    in
    pkgs.writeText "${name}-user-data" ''
      #cloud-config
      # Generated from lab.nix. Do not edit by hand — edit the topology.
      hostname: ${name}
      fqdn: ${name}.lab.local
      prefer_fqdn_over_hostname: false
      # false, not true: cloud-init rewrites /etc/hosts from a template on every
      # boot, which would silently undo the entries below each time you reboot.
      manage_etc_hosts: false

      users:
        - name: ${t.user}
          gecos: LFCS practice
          groups: [${d.adminGroup}]
          shell: /bin/bash
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          lock_passwd: false
          ssh_authorized_keys:
            - "@SSH_PUBKEY@"

      chpasswd:
        expire: false
        users:
          - name: ${t.user}
            password: ${t.password}
            type: text
          - name: root
            password: ${t.password}
            type: text

      ssh_pwauth: true
      disable_root: false

      growpart:
        mode: auto
        devices: ["/"]

      bootcmd:
      ${cmdList d.preflight}

      package_update: true
      packages:
      ${yamlList pkgList}

      write_files:
        - path: /etc/hosts
          permissions: "0644"
          content: |
      ${indent 6 hostsFile}

      runcmd:
      ${cmdList d.postflight}
        - systemctl enable --now serial-getty@ttyS0.service || true

      final_message: "${name} ready after $UPTIME seconds"
    '';

  metaData = name: pkgs.writeText "${name}-meta-data" ''
    instance-id: ${t.name}-${name}-001
    local-hostname: ${name}
  '';

  ##########################################################################
  # Manifest: everything the CLI needs, in one store path
  ##########################################################################

  manifest = pkgs.runCommand "${t.name}-lab-manifest" { } ''
    mkdir -p $out/networks $out/domains $out/cloud-init
    cp ${mgmtNet} $out/networks/${netName "mgmt"}.xml
    cp ${lanNet}  $out/networks/${netName "lan"}.xml
    ${lib.concatMapStringsSep "\n" (n: ''
      cp ${domainXml n t.nodes.${n}} $out/domains/${n}.xml
      mkdir -p $out/cloud-init/${n}
      cp ${userData n t.nodes.${n}} $out/cloud-init/${n}/user-data
      cp ${metaData n}              $out/cloud-init/${n}/meta-data
    '') nodeNames}
  '';

  ##########################################################################
  # CLI
  ##########################################################################

  runtimeDeps = with pkgs; [
    libvirt          # virsh
    qemu_kvm         # qemu-img
    xorriso          # cloud-init NoCloud seed ISO
    curl
    openssh
    coreutils
    gnused
    gnugrep
    util-linux
  ];

  bashHeader = ''
    LAB=${lib.escapeShellArg t.name}
    STATE=${lib.escapeShellArg t.stateDir}
    URI=${lib.escapeShellArg t.libvirtUri}
    LABUSER=${lib.escapeShellArg t.user}
    SUBNET=${lib.escapeShellArg mgmt.subnet}
    MANIFEST=${manifest}
    NODES=(${lib.concatStringsSep " " (map lib.escapeShellArg nodeNames)})
    AUTONODES=(${lib.concatStringsSep " " (map lib.escapeShellArg autoNodes)})
    NETS=(${netName "mgmt"} ${netName "lan"})
    declare -A NODE_IP=(${lib.concatMapStringsSep " " (n: "[${n}]=${ipOf t.nodes.${n}}") nodeNames})
    declare -A NODE_DISTRO=(${lib.concatMapStringsSep " " (n: "[${n}]=${t.nodes.${n}.distro}") nodeNames})
    declare -A NODE_EXTRA=(${lib.concatMapStringsSep " " (n: "[${n}]=${toString t.nodes.${n}.extraDisks}") nodeNames})
    declare -A NODE_EXTRAGB=(${lib.concatMapStringsSep " " (n: "[${n}]=${toString t.nodes.${n}.extraDiskGB}") nodeNames})
    declare -A NODE_ROOTGB=(${lib.concatMapStringsSep " " (n: "[${n}]=${toString t.nodes.${n}.rootGB}") nodeNames})
    declare -A IMG_URL=(${lib.concatMapStringsSep " " (k: "[${k}]=${lib.escapeShellArg t.images.${k}.url}") (lib.attrNames t.images)})
    declare -A IMG_FILE=(${lib.concatMapStringsSep " " (k: "[${k}]=${t.images.${k}.file}") (lib.attrNames t.images)})
  '';

  cli = pkgs.writeShellApplication {
    name = "lfcs-lab";
    runtimeInputs = runtimeDeps;
    text = bashHeader + builtins.readFile ./lfcs-lab.sh;
  };

in
{
  inherit manifest cli runtimeDeps;
  inherit nodeNames autoNodes;
}
