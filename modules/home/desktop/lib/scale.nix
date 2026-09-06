# The build gate for the geometry scale.
#
# Item 6 of docs/plans/desktop-design.md. The scale lives in lib/geometry.nix;
# dunst reads it directly because dunst is configured in Nix. waybar's CSS,
# rofi's theme and hyprland's settings.lua cannot: they are deployed verbatim
# so that configs/ works on a machine without Nix, and neither GTK 3 CSS nor
# rasi nor Lua has anywhere for a length variable to come from.
#
# So the scale reaches them backwards, the same way item 1 reached the bar's
# commands: a check at build time, whose output is what gets deployed. A radius
# that is not 12 or 8, a border that is not 2, or a margin that is not a
# multiple of 8 fails `nixos-rebuild switch` and fails CI.
#
# See ../geometry-scale.py for exactly which properties it looks at, and which
# it deliberately does not.
{ pkgs }:
let
  geometry = import ../../../../lib/geometry.nix;

  list = values: builtins.concatStringsSep "," (map toString values);
in
pkgs.writeShellApplication {
  name = "geometry-scale";
  runtimeInputs = [ pkgs.python3 ];
  text = ''
    exec python3 ${../geometry-scale.py} \
      ${
        list [
          geometry.radius.surface
          geometry.radius.chip
        ]
      } \
      ${list [ geometry.border ]} \
      ${
        list [
          geometry.space.unit
          geometry.space.half
        ]
      } \
      "$@"
  '';
}
