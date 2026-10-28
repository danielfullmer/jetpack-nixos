#!/bin/bash
# Runs on the IGX BMC: its firmware update service (orin-flash.sh) unpacks this
# package into /run/initramfs and executes this script. RCM-boots the
# jetpack-nixos flash initrd on the IGX host over the BMC's USB connection; the
# initrd writes the firmware to QSPI and reboots the host. Progress is read from
# the host's console, which the BMC already captures.

set -u

cd "$(dirname "$(readlink -f "$0")")" || exit 1

completion_timeout=@completionTimeout@
console_client_conf=/etc/obmc-console/client.2200.conf

# gpiochip0 line 4 selects where the host's recovery USB port goes: 0 = BMC,
# 1 = external USB-C connector.
route_usb() {
  gpioset -m exit gpiochip0 4="$1"
}
# Resets from RCM mode, including the flash initrd's own reboot, come back up in
# recovery mode, so reset the host as NVIDIA's bmcflashqspi.sh does.
trap 'route_usb 1; powerctrl reset' EXIT

host_in_recovery() {
  local dev
  for dev in /sys/bus/usb/devices/*; do
    if [ "$(cat "$dev/idVendor" 2>/dev/null)" = 0955 ] &&
      [ "$(cat "$dev/idProduct" 2>/dev/null)" = @apxProductId@ ]; then
      return 0
    fi
  done
  return 1
}

wait_for_recovery() {
  local i
  for ((i = 0; i < 10; i++)); do
    host_in_recovery && return 0
    sleep 1
  done
  return 1
}

route_usb 0
sleep 1
powerctrl recovery
if ! wait_for_recovery; then
  powerctrl reset
  sleep 1
  powerctrl recovery
  if ! wait_for_recovery; then
    powerctrl power_cycle
    route_usb 0
    sleep 1
    powerctrl recovery
    if ! wait_for_recovery; then
      echo "IGX host did not enter recovery mode" >&2
      exit 1
    fi
  fi
fi

if ! bash -e ./rcmbootcmd.txt; then
  echo "RCM boot of the IGX host failed" >&2
  exit 1
fi

if ! command -v obmc-console-client >/dev/null || [ ! -f "$console_client_conf" ]; then
  echo "Cannot read the IGX host console; waiting ${completion_timeout}s for flashing to finish"
  sleep "$completion_timeout"
  exit 0
fi

# obmc-console-client exits when its stdin reaches EOF, so give it a FIFO that
# we hold open for writing and never write to.
fifo=$(mktemp -u)
mkfifo "$fifo" || exit 1
exec 5<>"$fifo"
rm -f "$fifo"
exec 3< <(exec obmc-console-client -c "$console_client_conf" <&5)
console_pid=$!

status=2
deadline=$((SECONDS + completion_timeout))
while remaining=$((deadline - SECONDS)) && [ "$remaining" -gt 0 ] &&
  IFS= read -r -t "$remaining" -u 3 line; do
  line=${line%$'\r'}
  printf '%s\n' "$line"
  case "$line" in
  *"Flashing platform firmware successful"*)
    status=0
    break
    ;;
  *"Flashing platform firmware unsuccessful"*)
    status=1
    break
    ;;
  esac
done

kill "$console_pid" 2>/dev/null
exec 3<&- 5>&-

case "$status" in
0)
  echo "IGX host flashed successfully; resetting it"
  # Let the flash initrd finish its own sync and reboot first.
  sleep 10
  ;;
1) echo "IGX host reported that flashing failed" >&2 ;;
*) echo "IGX host console ended or ${completion_timeout}s passed before flashing finished" >&2 ;;
esac
exit "$status"
