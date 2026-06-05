{
  description = "Mellanox SR-IOV VF provisioning for Proxmox VE, built as a .deb";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      version = "1.0.0";
      # Architecture: all -- the .deb is identical regardless of build host.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          deb = pkgs.callPackage ./package.nix { inherit version; };
          default = deb;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC { packages = [ pkgs.dpkg pkgs.shellcheck ]; };
        }
      );
    };
}
