# Arguments for mkRcmBootScript that RCM-boot the flash initrd, which writes
# the firmware to the boot storage and reboots. Shared by initrdFlashScript
# (host-driven) and igxBmcQspiFwpkg (BMC-driven).
{ config
, flashInitrd
, lib
, l4tMajorMinorPatchVersion
, writeText
, deviceTree
,
}:
let
  cfg = config.hardware.nvidia-jetpack;

  forceXusbPeripheralDts =
    let
      overridePaths = {
        "39" = {
          thor = {
            xudcPadctlPath = "bus@0/padctl@a808680000";
            xudcPath = "bus@0/usb@a808670000";
          };
          orin = {
            xudcPadctlPath = "bus@0/padctl@3520000";
            xudcPath = "bus@0/usb@3550000";
          };
        };
        "36" = {
          orin = {
            xudcPadctlPath = "bus@0/padctl@3520000";
            xudcPath = "bus@0/usb@3550000";
          };
        };
        "35" = {
          orin = {
            xudcPadctlPath = "xusb_padctl@3520000";
            xudcPath = "xudc@3550000";
          };
          xavier = {
            xudcPadctlPath = "xusb_padctl@3520000";
            xudcPath = "xudc@3550000";
          };
        };
      };
      l4tMajor = lib.versions.major l4tMajorMinorPatchVersion;
      soc = builtins.elemAt (lib.strings.split "-" cfg.som) 0;
      inherit (overridePaths.${l4tMajor}.${soc}) xudcPadctlPath xudcPath;
    in
    writeText "dts" ''
      /dts-v1/;

      / {
        fragment@0 {
          target-path = "/${xudcPadctlPath}/ports/usb2-0";

          board_config {
            sw-modules = "kernel", "uefi";
          };

          __overlay__ {
            mode = "peripheral";
            /* usb-role-switch and connector are required
              * use a dummy connector that claims USB is connected at boot
              */
            usb-role-switch;
            connector {
              compatible = "usb-b-connector", "gpio-usb-b-connector";
              label = "usb-recovery";
              cable-connected-on-boot = <2>;
            };
          };
        };

        fragment@1 {
          target-path = "/${xudcPath}";

          board_config {
            sw-modules = "kernel", "uefi";
          };

          __overlay__ {
            status = "okay";
          };
        };
      };
    '';
  forceXusbPeripheralDtbo = deviceTree.compileDTS {
    # We force USB port to peripheral mode, in case the carrier board doesn't support OTG
    # Fortunately, the USB controller is all in the SoC, so we can override it directly here
    name = "force-xusb-peripheral.dtbo";
    dtsFile = forceXusbPeripheralDts;
  };
in
{
  kernelPath = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
  initrdPath = "${flashInitrd}/initrd";
  kernelCmdline = [
    "sdhci_tegra.en_boot_part_access=1"
    "clk_ignore_unused"
  ] ++ cfg.console.args;
  # During the initrd flash script, we upload two edk2 builds to the
  # board, one that is only used temporarily to boot into our
  # kernel/initrd to perform the flashing, and another one that is
  # persisted to the firmware storage medium for future booting. We
  # don't want to influence the boot order of the temporary edk2 since
  # this may cause that edk2 to boot from something other than our
  # intended flashing kernel/initrd combo (e.g. disk or network). Since
  # the edk2 build that we actually persist to the board is embedded in
  # the initrd used for flashing, we have the desired boot order (as
  # configured in nix) in there and is not affected dynamically during
  # the flashing procedure. NVIDIA ensures that when the device is
  # using RCM boot, only the boot mode named "boot.img" is used (see https://gist.github.com/jmbaur/1ca79436e69eadc0a38ec0b43b16cb2f#file-flash-sh-L1675).
  additionalDtbOverlays = (lib.filter (path: (path.name or "") != "DefaultBootOrder.dtbo") cfg.flashScriptOverrides.additionalDtbOverlays) ++ [ forceXusbPeripheralDtbo ];
}
