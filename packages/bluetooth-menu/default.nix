# bluetooth-menu: connect, disconnect and discover bluetooth devices.
#
# Item 9 of docs/plans/desktop-design.md. Bluetooth had no visual path either
# - blueman was installed, its applet was explicitly off, and nothing used
# either. This is the connect/disconnect/discover path, over bluetoothctl.
#
# The list is paired and discoverable devices: everything bluetoothctl knows,
# marked by state (connected, paired, or just discovered), plus a scan entry
# that runs a bounded discovery scan and re-opens the menu so freshly seen
# devices appear. Connecting to an unpaired device lets bluetoothctl pair it
# when no PIN is involved.
#
# A PIN is the one thing item 7 said a menu should not ask for, which is why
# the package carries blueman: the "Pair a new device" entry opens
# blueman-manager, the on-demand pairing tool, and the half-installed blueman
# package gains its stated purpose.
{
  lib,
  pkgs,
}:
let
  mkMenu = import ../lib/mk-menu.nix {
    inherit lib;
    writeShellApplication = pkgs.writeShellApplication;
    rofi-menu = pkgs.rofi-menu;
  };
in
mkMenu {
  name = "bluetooth-menu";
  prompt = "Bluetooth";
  rows = 10;

  runtimeInputs = [
    pkgs.bluez # bluetoothctl
    pkgs.coreutils # timeout, for the bounded scan
    pkgs.libnotify # notify-send, so the scan is announced rather than silent
    pkgs.blueman # blueman-manager, the pairing path a menu should not attempt
  ];

  # Everything bluetoothctl knows, state-marked: connected with a filled dot,
  # paired-but-idle with an open one, discovered-but-unpaired flagged so the
  # user can see what a connect would try to pair. Scanning and pairing last,
  # both sentinel rows that cannot be a device address. Each row is
  # `NAME<TAB>MAC` so a name with spaces round-trips. The sentinel lines are
  # the group's last commands, so the group always succeeds even if
  # bluetoothctl hiccups on the devices list.
  list = ''
    {
      bluetoothctl devices 2>/dev/null | while read -r _ mac name; do
        [ -n "$mac" ] || continue
        if bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
          printf '● %s\t%s\n' "$name" "$mac"
        elif bluetoothctl info "$mac" 2>/dev/null | grep -q "Paired: yes"; then
          printf '○ %s\t%s\n' "$name" "$mac"
        else
          printf '◇ %s (discovered)\t%s\n' "$name" "$mac"
        fi
      done || true
      printf '󰂲 Scan for devices…\t__scan__\n'
      printf '󰂲 Pair a new device…\t__pair__\n'
    }
  '';

  action = ''
    mac="''${choice#*$'\t'}"
    case "$mac" in
      __scan__)
        # A bounded discovery scan - bluetoothctl scan blocks until told to
        # stop, so timeout ends it - announced once, then the menu re-opens
        # with whatever was found. New devices arrive unpaired; connect
        # handles the PIN-less case below and a PIN stays blueman-manager's.
        notify-send "Scanning for bluetooth devices (12s)…" || true
        timeout 12 bluetoothctl scan on >/dev/null 2>&1 || true
        exec bluetooth-menu
        ;;
      __pair__)
        exec blueman-manager
        ;;
      "")
        exit 0
        ;;
      *)
        if bluetoothctl info "$mac" | grep -q "Connected: yes"; then
          bluetoothctl disconnect "$mac"
        else
          bluetoothctl connect "$mac"
        fi
        ;;
    esac
  '';
}
