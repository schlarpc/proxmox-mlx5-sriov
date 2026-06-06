{
  description = "Mellanox SR-IOV VF provisioning for Proxmox VE, built as a .deb";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      baseVersion = "1.0.0";
      # Tie the .deb version to the commit it was built from, while keeping it
      # monotonic so apt's "is this newer?" comparison behaves. A bare commit
      # hash is NOT monotonic (hex sorts arbitrarily vs. commit order), so apt
      # would treat half of all upgrades as downgrades. Leading with the commit
      # date (`lastModifiedDate`, "YYYYMMDDHHMMSS" -- set from the commit even on
      # a shallow CI checkout) fixes the ordering; the short rev is a tiebreaker
      # and the human-readable link back to the source. `+` (not `~`) because
      # these builds come after the 1.0.0 baseline. A dirty/local tree has no
      # rev, so it falls back to a marker (still a valid Debian version: no bare
      # `-`, which would be read as the debian-revision separator).
      version = "${baseVersion}+${self.lastModifiedDate}.g${self.shortRev or "dirty"}";
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
