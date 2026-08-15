# Waybar click handler for the NixOS upgrade module.
#
#   left    apply what is pending (system update, then firmware)
#   right   build now, rather than waiting for the daily timer
#   middle  open the logs
#
# Applying is a systemd unit rather than work done here: it needs root, it must
# survive waybar restarting or the bar being killed mid-upgrade, and its
# ActiveState is what the status script reads back. Starting it is permitted
# for wheel by the polkit rule in modules/nixos/auto-upgrade.nix.
#
# Runs under `set -euo pipefail`, so anything allowed to fail is written as an
# `if` rather than `cmd && ...` at statement level.

NEXT_LINK="/var/lib/nixos-upgrade/next"
CURRENT="/run/current-system"
BOOTED="/run/booted-system"

# Accept both `left` and `--button left`; waybar's config uses the latter.
button="${1:-left}"
if [ "$button" = "--button" ]; then
  button="${2:-left}"
fi

notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "NixOS Upgrade" "$@" || true
  fi
}

start_unit() {
  unit="$1"
  # The polkit rule normally makes this succeed for wheel without a prompt.
  # pkexec is the fallback for a session where polkit is unavailable.
  if systemctl start "$unit" 2>/dev/null; then
    return 0
  fi
  if pkexec systemctl start "$unit" 2>/dev/null; then
    return 0
  fi
  notify -u critical "Could not start $unit" "Try: sudo systemctl start $unit"
  return 1
}

kernel_of() {
  readlink "$1"/{initrd,kernel,kernel-modules} 2>/dev/null || true
}

firmware_count() {
  if command -v fwupdmgr >/dev/null 2>&1; then
    fwupdmgr get-updates --json 2>/dev/null | jq '.Devices | length' 2>/dev/null || echo 0
  else
    echo 0
  fi
}

case "$button" in
right)
  notify -u low "Checking for updates" "Building in the background…"
  start_unit nixos-upgrade-build.service
  ;;

middle)
  if command -v ghostty >/dev/null 2>&1; then
    ghostty -e journalctl -u "nixos-upgrade-*" -f -n 200 &
  else
    notify -u normal "No terminal found" "Run: journalctl -u 'nixos-upgrade-*' -f"
  fi
  ;;

left)
  next=""
  if [ -L "$NEXT_LINK" ]; then
    next="$(readlink -f "$NEXT_LINK" 2>/dev/null || true)"
  fi
  current="$(readlink -f "$CURRENT" 2>/dev/null || true)"

  if [ -n "$next" ] && [ "$next" != "$current" ]; then
    notify -u low "Applying updates" "This may take a few minutes…"
    start_unit nixos-upgrade-apply.service
    exit 0
  fi

  # Nothing new to switch to, but the running kernel is not the booted one:
  # the only thing left to do is reboot.
  booted_kernel="$(kernel_of "$BOOTED")"
  current_kernel="$(kernel_of "$CURRENT")"
  if [ -n "$booted_kernel" ] && [ "$booted_kernel" != "$current_kernel" ]; then
    notify -u normal "Reboot required" "The update is applied; reboot to finish."
    exit 0
  fi

  fw_count="$(firmware_count)"
  if [ "$fw_count" -gt 0 ]; then
    notify -u low "Applying firmware updates" "Some devices may need a reboot."
    start_unit nixos-upgrade-firmware.service
    exit 0
  fi

  notify -u low "Up to date" "Nothing to apply."
  ;;

*)
  echo "usage: $0 [left|right|middle]" >&2
  exit 2
  ;;
esac
