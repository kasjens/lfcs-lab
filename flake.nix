{
  description = "A disposable LFCS practice lab: libvirt/KVM guests declared in Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      # amd64 cloud images, so amd64 hosts. An aarch64 lab needs different
      # image URLs and machine='virt' in the domain template.
      systems = [ "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      topology = import ./lab.nix;
      labFor = pkgs: import ./lib/mklab.nix { inherit pkgs topology; };
    in
    {
      packages = forAll (pkgs:
        let lab = labFor pkgs; in {
          default = lab.cli;
          lfcs-lab = lab.cli;
          # `nix build .#manifest && ls -R result` to read the generated
          # libvirt XML and cloud-init before anything touches your machine.
          manifest = lab.manifest;
        });

      apps = forAll (pkgs:
        let lab = labFor pkgs; in {
          default = {
            type = "app";
            program = "${lab.cli}/bin/lfcs-lab";
          };
        });

      devShells = forAll (pkgs:
        let lab = labFor pkgs; in {
          default = pkgs.mkShell {
            packages = [ lab.cli ] ++ lab.runtimeDeps;
            shellHook = ''
              echo "lfcs-lab in scope. Topology: ${
                nixpkgs.lib.concatStringsSep " " lab.nodeNames
              }"
              echo "  lfcs-lab install    first run, downloads images"
              echo "  lfcs-lab status     where things stand"
            '';
          };
        });

      # Optional: if the host itself is NixOS, import this to get libvirtd.
      nixosModules.host = import ./lib/host-module.nix;

      formatter = forAll (pkgs: pkgs.nixpkgs-fmt);
    };
}
