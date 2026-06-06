{
  lib,
  stdenvNoCC,
  dpkg,
  version,
}:

stdenvNoCC.mkDerivation {
  pname = "proxmox-mlx5-sriov-deb";
  inherit version;

  src = ./.;

  nativeBuildInputs = [ dpkg ];

  # The payload runs on Debian/Proxmox, not in the Nix store, so keep its
  # `/usr/bin/env bash` shebangs and skip Nix's fixup phase entirely.
  dontConfigure = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    root="$NIX_BUILD_TOP/pkgroot"

    # payload
    install -Dm755 bin/mlx5-sriov-create-vfs   "$root/usr/sbin/mlx5-sriov-create-vfs"
    install -Dm755 bin/mlx5-sriov-sync-mappings "$root/usr/sbin/mlx5-sriov-sync-mappings"
    install -Dm644 systemd/mlx5-sriov-vfs@.service      "$root/lib/systemd/system/mlx5-sriov-vfs@.service"
    install -Dm644 systemd/mlx5-sriov-mappings@.service "$root/lib/systemd/system/mlx5-sriov-mappings@.service"
    # Stable, hardware-derived representor names (pf0vf0..) applied at next boot
    # when the VFs are (re-)created. Package-owned rule, so it lives in /lib;
    # /etc/udev/rules.d/ is left for admin overrides.
    install -Dm644 udev/70-mlx5-vf-representors.rules "$root/lib/udev/rules.d/70-mlx5-vf-representors.rules"
    # Drop-in directory for optional per-PF overrides (admin-created, not shipped).
    install -d "$root/etc/default/mlx5-sriov.d"

    # Example bridge-ports line matching the representor names above. Shipped as
    # documentation only -- the package does not manage /etc/network/interfaces.
    install -Dm644 network/interfaces.snippet \
      "$root/usr/share/doc/proxmox-mlx5-sriov/examples/interfaces.snippet"

    # control metadata
    install -Dm644 debian/control   "$root/DEBIAN/control"
    install -Dm755 debian/postinst  "$root/DEBIAN/postinst"
    install -Dm755 debian/postrm    "$root/DEBIAN/postrm"

    substituteInPlace "$root/DEBIAN/control" --replace-fail '@VERSION@' '${version}'

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    # SOURCE_DATE_EPOCH (exported by stdenv) makes dpkg-deb output reproducible.
    dpkg-deb --root-owner-group --build "$NIX_BUILD_TOP/pkgroot" \
      "$out/proxmox-mlx5-sriov_${version}_all.deb"
    runHook postInstall
  '';

  meta = {
    description = "Mellanox SR-IOV VF provisioning for Proxmox VE (.deb)";
    platforms = lib.platforms.all;
  };
}
