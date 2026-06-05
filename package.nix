{
  lib,
  stdenvNoCC,
  dpkg,
  version,
}:

stdenvNoCC.mkDerivation {
  pname = "sriov-vfs-deb";
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
    install -Dm755 bin/create-sriov-vfs       "$root/opt/schlarpc/bin/create-sriov-vfs"
    install -Dm755 bin/sync-sriov-vf-mappings "$root/opt/schlarpc/bin/sync-sriov-vf-mappings"
    install -Dm644 systemd/sriov-vfs.service          "$root/lib/systemd/system/sriov-vfs.service"
    install -Dm644 systemd/sriov-vf-mappings.service  "$root/lib/systemd/system/sriov-vf-mappings.service"
    install -Dm644 etc/default/sriov-vfs      "$root/etc/default/sriov-vfs"

    # control metadata
    install -Dm644 debian/control   "$root/DEBIAN/control"
    install -Dm644 debian/conffiles "$root/DEBIAN/conffiles"
    install -Dm755 debian/postinst  "$root/DEBIAN/postinst"
    install -Dm755 debian/prerm     "$root/DEBIAN/prerm"
    install -Dm755 debian/postrm    "$root/DEBIAN/postrm"

    substituteInPlace "$root/DEBIAN/control" --replace-fail '@VERSION@' '${version}'

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    # SOURCE_DATE_EPOCH (exported by stdenv) makes dpkg-deb output reproducible.
    dpkg-deb --root-owner-group --build "$NIX_BUILD_TOP/pkgroot" \
      "$out/sriov-vfs_${version}_all.deb"
    runHook postInstall
  '';

  meta = {
    description = "Mellanox SR-IOV VF provisioning for Proxmox VE (.deb)";
    platforms = lib.platforms.all;
  };
}
