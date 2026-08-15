# packages/nixos-upgrade-scripts/default.nix
#
# Waybar front-end for the NixOS upgrade module on desktops.
#
# This used to be ~1800 lines of Python that ran `nix flake update`, decided
# what to build, built it, applied it, committed the result, and kept a JSON
# state machine describing where it had got to. CI now owns the lock (ADR 0001)
# and the hosts follow a promoted ref, so all that remains here is the desktop
# affordance: show what is pending and let the user apply it.
#
# The state machine went with it. Everything the indicator reports is read from
# systemd or from the store at display time, so it cannot drift out of sync
# with what is actually true.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  jq,
  systemd,
  libnotify,
  polkit,
  fwupd,
  ghostty,
}:
let
  status = writeShellApplication {
    name = "nixos-upgrade-waybar";
    runtimeInputs = [
      jq
      systemd
      fwupd
    ];
    text = builtins.readFile ./waybar-status.sh;
  };

  click = writeShellApplication {
    name = "nixos-upgrade-waybar-click";
    runtimeInputs = [
      jq
      systemd
      libnotify
      polkit
      fwupd
      ghostty
    ];
    text = builtins.readFile ./waybar-click.sh;
  };
in
symlinkJoin {
  name = "nixos-upgrade-scripts";
  paths = [
    status
    click
  ];

  meta = {
    description = "Waybar indicator and click handler for NixOS upgrades";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
