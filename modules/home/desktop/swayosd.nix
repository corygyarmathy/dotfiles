# SwayOSD - item 12 of docs/plans/desktop-design.md.
#
# Volume, mute and brightness keys had no immediate confirmation - the bar's
# module is small, may be on another monitor, and after item 21 rotates the
# bar there is no room for a number at all. swayosd-client both performs the
# change and shows the OSD, centred over the focused output, and it is
# transient and undismissable, which is a different job from a notification -
# the reason this item exists even though dunst already has a progress bar.
#
# It is a new daemon, which principle 6's ordering asks to justify: the
# justification is that this is a surface that should appear centred, over
# the focused output, and disappear without being dismissed - a different job
# from a notification, done by a process whose only job that is.
#
# And it has no stylix target, so it joins item 5's generated-colour scheme
# from its first commit: configs/swayosd/style.css is generated from
# lib/kanagawa-wave.nix and checked in, and the build gates the copy - the
# palette match, the geometry scale, and (because swayosd only warns and
# carries on) that GTK 4 will parse it at all.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.swayosd;

  configs = ../../../configs/swayosd;

  palette = import ../../../lib/kanagawa-wave.nix { inherit lib; };
  inherit (import ./lib/generated.nix { inherit pkgs; }) assertGenerated;
  geometryScale = import ./lib/scale.nix { inherit pkgs; };
  swayosdCssParse = import ./lib/swayosd-css.nix { inherit pkgs; };

  checkedStyle = pkgs.runCommand "swayosd-style.css" { } ''
    ${assertGenerated [
      {
        path = "configs/swayosd/style.css";
        deployed = "${configs}/style.css";
        expected = palette.toSwayosdCss;
      }
    ]}

    ${geometryScale}/bin/geometry-scale ${configs}/style.css

    ${swayosdCssParse}/bin/swayosd-css-parse ${configs}/style.css

    cp ${configs}/style.css $out
    chmod u+w $out
  '';
in
{
  options.cg.home.swayosd.enable = lib.mkEnableOption "SwayOSD volume and brightness overlay";

  config = lib.mkIf cfg.enable {
    services.swayosd.enable = true;

    # swayosd reads ~/.config/swayosd/style.css itself and falls back to its
    # default theme when the file is absent - so the deployed file is the
    # check's output, and a hand-edited colour or an off-scale length cannot
    # be switched to. The OSD sits at the server's default top-margin (0.85,
    # near the bottom); item 21 positions it against the new bar geometry
    # when that lands.
    xdg.configFile."swayosd/style.css".source = checkedStyle;
  };
}
