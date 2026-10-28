{ rcmScript
, config
, flashInitrd
, lib
, writeText
, tio
, expect
,
}:
let
  cfg = config.hardware.nvidia-jetpack;
  inherit (flashInitrd.passthru) manufacturer product serialnumber;
  serialPortId = "usb-${manufacturer}_${product}_${serialnumber}-if00";
  expectScript = writeText "expect-initrd-flash" ''
    set modem /dev/serial/by-id/${serialPortId}

    send_user "connecting to $modem\n"
    # --log-strip -> Strip control characters and escape sequences
    # --mute -> Mute tio messages
    spawn -noecho "${lib.getExe tio}" --log-strip --mute "$modem"
    set timeout ${builtins.toString cfg.flashScriptOverrides.initrdFlashCompletionTimeoutSeconds}
    set failed 0
    expect {
      "Flashing platform firmware successful" {
        exit
      }
      "Flashing platform firmware unsuccessful" {
        set timeout 2
        set failed 1
        exp_continue
      }
      "Entering console" {
        interact {
          # \003 is Ctrl-C
          \003   exit 1
          ~~
        }
      }
      timeout {
        if {$failed == 1} {
          exit 1
        } else {
          send_user "connection to device timed out\n"
          exit 2
        }
      }
      eof {
        send_user "Connection to device failed: $expect_out(buffer)"
        exit 2
      }
    }
  '';
in
''
  ${rcmScript}

  echo
  echo "Jetson device should now be flashing and will reboot when complete."

  # TODO(eberman): maybe stop assuming /dev/serial/by-id is present
  # It'll be populated with udev, so most Linux systems will work fine
  echo -n "Waiting up to ${builtins.toString cfg.flashScriptOverrides.initrdFlashSerialEnumerateTimeoutSeconds}s for Jetson device to appear via USB"

  counter=0
  until [[ -e /dev/serial/by-id/${serialPortId} || $counter -gt ${builtins.toString (cfg.flashScriptOverrides.initrdFlashSerialEnumerateTimeoutSeconds * 2)} ]] ; do
    echo -n "."
    sleep 0.5
    ((++counter))
  done
  echo

  if [ ! -e /dev/serial/by-id/${serialPortId} ] ; then
    echo "Jetson device not detected, please monitor the serial port or wait 5-15 minutes"
    exit 2
  fi

  if ! ${lib.getExe expect} -f ${expectScript} ; then
    echo "Flashing may have failed"
    exit 1
  fi
  echo "Device reported flashing succeeded. Device should be rebooting."
''
