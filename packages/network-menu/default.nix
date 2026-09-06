# network-menu: connect to a wifi network, from a menu.
#
# Item 9 of docs/plans/desktop-design.md. Changing wifi networks had no
# visual path at all before this - nmtui in a terminal or nothing. The menu
# lists saved and visible networks with signal strength, connects on pick,
# and asks for a passphrase when the network is not saved yet.
#
# One deliberate boundary, from the item: a menu does one thing, and editing
# connection profiles is not that thing - that is `full` depth on the
# escalation ladder and belongs to nm-connection-editor. This connects to
# networks. It does not edit them.
#
# The passphrase is the one case that does not go through rofi-menu: it is a
# prompt, not a list of answers, so rofi's own -password flag is used for it.
# It still loads the shared theme, because rofi reads config.rasi by default.
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
  name = "network-menu";
  prompt = "Network";
  rows = 12;

  runtimeInputs = [
    pkgs.networkmanager # nmcli
    pkgs.rofi # the passphrase prompt, the one non-list rofi this desktop runs
  ];

  # SSID and signal, tab-separated so a name containing spaces round-trips.
  # `--escape no` reads an SSID containing a colon, at the cost of one that
  # does; `--rescan auto` refreshes the list when the last scan is stale but
  # does not force a slow rescan every time the menu opens. In-progress
  # scans show "--" and are skipped rather than offered.
  list = ''
    {
      nmcli -t --escape no -f SSID,SIGNAL device wifi list --rescan auto 2>/dev/null |
        awk -F: 'NF >= 2 && $1 != "" && $1 != "--" { printf "%s\t%3s%%\n", $1, $2 }' || true
    }
  '';

  action = ''
    ssid="''${choice%%$'\t'*}"
    [ -n "$ssid" ] || exit 0

    # Saved, then, is decided on the connection *name* field alone: a terse
    # `connection show` line is NAME:UUID:TYPE:DEVICE, and a whole-line match
    # would never fire. `-g NAME` prints just the names, unescaped, one per
    # line - fixed-string still, so an SSID full of regex is still an SSID.
    if nmcli -g NAME connection show | grep -Fqx "$ssid"; then
      nmcli connection up "$ssid"
    else
      password="$(rofi -dmenu -password -p "Password for $ssid")"
      nmcli device wifi connect "$ssid" password "$password"
    fi
  '';
}
