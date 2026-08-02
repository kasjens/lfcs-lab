# Only useful if the *host* is NixOS. On any other distro, install libvirt
# through your package manager and make sure libvirtd is running — the flake's
# devShell supplies virsh, qemu-img and xorriso either way.
#
#   imports = [ inputs.lfcs-lab.nixosModules.host ];
#   users.users.<you>.extraGroups = [ "libvirtd" "kvm" ];
{ pkgs, ... }:
{
  virtualisation.libvirtd = {
    enable = true;
    qemu.package = pkgs.qemu_kvm;
    qemu.runAsRoot = true;
    # Do not resurrect the lab on every boot; `lfcs-lab up` is explicit.
    onBoot = "ignore";
    onShutdown = "shutdown";
  };

  # Guests reach the outside through the NAT network's bridge.
  networking.firewall.trustedInterfaces = [ "vbr-lfcsm" ];

  environment.systemPackages = with pkgs; [
    libvirt
    qemu_kvm
    xorriso
  ];
}
