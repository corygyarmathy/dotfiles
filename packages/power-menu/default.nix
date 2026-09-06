# power-menu: shut down, reboot, suspend, log out or lock, from one menu.
#
# Item 8 of docs/plans/desktop-design.md. There was no visual way to shut
# down or reboot - SUPER+S only locks, everything else was a terminal command.
# This is that visual path: a rofi menu over loginctl and systemctl.
#
# No confirmation, on purpose. The menu is already two layers - opening it is
# one decision, picking the entry is the second - which is enough deliberation
# for an action that costs an unsaved buffer. That is why destructive entries
# come last and the bare-Return fast path lands on Lock: a one-step action
# gets a confirmation, a two-step one does not, and binding SUPER+SHIFT+Q
# straight to shutdown later would collapse the layers and have to bring a
# confirmation back with it.
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
  name = "power-menu";
  prompt = "Power";
  rows = 5;

  runtimeInputs = [
    # loginctl, systemctl: the session and system commands below.
    pkgs.systemd
    # hyprctl talks to the running compositor; logging out is the
    # compositor's decision to make, not loginctl's, because UWSM watches
    # the session end.
    pkgs.hyprland
  ];

  # Destructive entries ordered last, and never first: the fast path (a bare
  # Return on an empty filter) lands on Lock.
  list = ''
    printf '%s\n' \
      '󰌾 Lock' \
      '󰒲 Suspend' \
      '󰍃 Log out' \
      '󰜉 Reboot' \
      '󰐥 Power off'
  '';

  action = ''
    case "$choice" in
      '󰌾 Lock') loginctl lock-session ;;
      '󰒲 Suspend') systemctl suspend ;;
      '󰍃 Log out') hyprctl dispatch exit ;;
      '󰜉 Reboot') systemctl reboot ;;
      '󰐥 Power off') systemctl poweroff ;;
    esac
  '';
}
