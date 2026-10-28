# QSPI firmware package for the IGX BMC's update service (Web UI / Redfish
# UpdateService). Same layout as NVIDIA's
# tools/qspi_flash/generate_qspi_for_flash.sh --flash-mode BMC: a PLDM package
# whose single component is a tarball of ./bmcflash. The BMC unpacks it into
# /run/initramfs, records bmcflash/version.txt as the host firmware version, and
# runs bmcflash/bmcflashqspi.sh.
{ config
, lib
, runCommand
, writeText
, fetchurl
, python3
, socType
, l4tMajorMinorPatchVersion
, # flash-tools-flashcmd built with `--rcm-boot --no-flash`, which leaves the
  # tegrarcm commands and the images they upload in bootloader/rcmboot_blob.
  flash-tools
}:
let
  cfg = config.hardware.nvidia-jetpack;
  # NVIDIA's webui update bundle: a bzip2 tarball of PLDM .fwpkg files, not a .fwpkg itself.
  # We only need the 32-bit ARM tegrarcm_v2 from its QSPI flash package.
  referenceTbz2 = fetchurl {
    url = "https://developer.nvidia.com/downloads/igx/v2.0.1/igx_fw_for_webui_update_r38.5.1.tbz2";
    hash = "sha256-uL+OGpnIq2OTk+CJbXQYHfP+DZjT6JAQNO7MpZw4Mck=";
  };

  # `referenceMember` is the QSPI flash package holding tegrarcm_v2 inside `referenceTbz2`, which
  # is the IGX Thor bundle; an IGX Orin build needs that SoC's own bundle URL.
  platform = {
    t234 = { name = "IGX-Orin"; releaseDateTime = "22/01/2024 00:00:00"; apxProductId = "7023"; referenceMember = "./igx-orin-qspi-flash.fwpkg"; };
    t264 = { name = "IGX-Thor"; releaseDateTime = "05/08/2025 00:00:00"; apxProductId = "7026"; referenceMember = "./igx-thor-qspi-flash.fwpkg"; };
  }.${socType} or (throw "igxBmcQspiFwpkg: unsupported SoC ${socType}; IGX BMCs host Orin (t234) or Thor (t264)");

  # Same values as NVIDIA's bmc/tools/igx-{orin,thor}.json. The BMC only accepts packages whose
  # descriptor matches its ORIN_SUPPORTED_MODEL (shared by Orin and Thor).
  pldmMetadata = writeText "igx-qspi-flash.json" (builtins.toJSON {
    PackageHeaderInformation = {
      PackageHeaderIdentifier = "F018878CCB7D49439800A02F059ACA02";
      PackageHeaderFormatVersion = 1;
      PackageReleaseDateTime = platform.releaseDateTime;
      PackageVersionString = platform.name;
    };
    FirmwareDeviceIdentificationArea = [{
      DeviceUpdateOptionFlags = [ ];
      ComponentImageSetVersionString = platform.name;
      ApplicableComponents = [ 0 ];
      Descriptors = [{ DescriptorType = 2; DescriptorData = "4e261656fff8777265bdc5d1ba3ec0ab"; }];
    }];
    ComponentImageInformationArea = [{
      ComponentClassification = 0;
      ComponentIdentifier = 0;
      ComponentOptions = [ 0 ];
      RequestedComponentActivationMethod = [ ];
      ComponentVersionString = platform.name;
    }];
  });

  # Produces byte-identical output to the copy NVIDIA ships in bmc/tools for the same inputs.
  pldmFwupPkgCreator = fetchurl {
    url = "https://raw.githubusercontent.com/openbmc/pldm/50609c9c3d18c0605e9e0349e16e2dd8bf68c6e0/tools/fw-update/pldm_fwup_pkg_creator.py";
    hash = "sha256-ts70jv5W3JkqcLKWulzHi/AKdVe5aJrtyxJCerDKY3U=";
  };
in
# The rcmboot blob is generated before the flash script signs boot.img.
assert lib.assertMsg (cfg.firmware.secureBoot.pkcFile == null) "igxBmcQspiFwpkg does not support secure boot yet";
runCommand "igx-qspi-flash-${cfg.name}.fwpkg"
{
  nativeBuildInputs = [ (python3.withPackages (p: [ p.bitarray ])) ];
}
  ''
    if [ ! -f ${flash-tools}/bootloader/rcmboot_blob/rcmbootcmd.txt ]; then
      echo "flash.sh did not produce bootloader/rcmboot_blob/rcmbootcmd.txt" >&2
      exit 1
    fi
    cp -r ${flash-tools}/bootloader/rcmboot_blob bmcflash
    chmod -R u+w bmcflash

    # The rcmboot blob carries the x86_64 tegrarcm_v2, but the BMC needs NVIDIA's 32-bit ARM build.
    # It lives in their QSPI flash .fwpkg, a member of the bzip2'd reference bundle. That package's
    # single component directly follows its header, whose size is the little-endian u16 at offset 17.
    if ! tar -xjf ${referenceTbz2} -O ${platform.referenceMember} >reference.fwpkg; then
      echo "${referenceTbz2} has no ${platform.referenceMember}" >&2
      exit 1
    fi
    header_size=$(od -An -tu2 -j17 -N2 --endian=little reference.fwpkg | tr -d ' ')
    tail -c +$((header_size + 1)) reference.fwpkg | tar -xOf - ./bmcflash/tegrarcm_v2 >bmcflash/tegrarcm_v2
    # ELF class 1 (32-bit) and e_machine 0x28 (ARM)
    if [ "$(od -An -tx1 -j4 -N1 bmcflash/tegrarcm_v2 | tr -d ' ')" != 01 ] ||
      [ "$(od -An -tx1 -j18 -N2 bmcflash/tegrarcm_v2 | tr -d ' ')" != 2800 ]; then
      echo "tegrarcm_v2 from ${referenceTbz2} is not a 32-bit ARM executable" >&2
      exit 1
    fi
    chmod 0755 bmcflash/tegrarcm_v2

    substitute ${./igx-bmcflashqspi.sh} bmcflash/bmcflashqspi.sh \
      --subst-var-by completionTimeout ${toString cfg.flashScriptOverrides.initrdFlashCompletionTimeoutSeconds} \
      --subst-var-by apxProductId ${platform.apxProductId}
    chmod 0755 bmcflash/bmcflashqspi.sh

    # Shown by the BMC as the host firmware version.
    printf 'R%s-nixos-%s' ${l4tMajorMinorPatchVersion} "$(basename ${flash-tools} | cut -c1-8)" >bmcflash/version.txt

    # Uncompressed despite NVIDIA naming it .tbz2: the BMC extracts it with a plain `tar -xvf`.
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf bmcflash.tar ./bmcflash
    python3 ${pldmFwupPkgCreator} $out ${pldmMetadata} bmcflash.tar
  ''
