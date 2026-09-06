# Rofi application launcher
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.rofi;

  configs = ../../../configs/rofi;

  palette = import ../../../lib/kanagawa-wave.nix { inherit lib; };
  inherit (import ./lib/generated.nix { inherit pkgs; }) assertGenerated;
  geometryScale = import ./lib/scale.nix { inherit pkgs; };

  # The same bargain waybar.nix makes, for the same reason: themes/palette.rasi
  # is generated from lib/kanagawa-wave.nix and checked in so that configs/rofi
  # works standalone, and the build is what keeps the copy honest. See
  # ./lib/generated.nix, and item 5 of docs/plans/desktop-design.md.
  #
  # themes/kanagawa-wave.rasi is hand-written and carries no hex; it imports
  # palette.rasi by a relative name, which rofi resolves against the including
  # file's own directory, so the pair travels together. Nor does it carry a
  # loose length: item 6's geometry scale is checked here too, the same way
  # waybar's stylesheets are. See ./lib/scale.nix.
  #
  # The second gate is the one this item earned the hard way. rofi does not
  # fail when a theme does not parse: it logs a warning nobody is reading and
  # silently loads its own default, so a broken theme looks like a launcher
  # that has quietly reverted to Solarized. `-dump-theme` parses the file and
  # exits without needing a display, which makes that checkable at build time -
  # the same bargain as the bar's command check in waybar.nix.
  #
  # It is also what caught the reason `highlight` is generated rather than
  # written by hand: rofi's grammar takes a literal colour there and rejects a
  # reference, and the theme that tried one parsed as nothing at all.
  checkedConfigs = pkgs.runCommand "rofi-config" { nativeBuildInputs = [ pkgs.rofi ]; } ''
    ${assertGenerated [
      {
        path = "configs/rofi/themes/palette.rasi";
        deployed = "${configs}/themes/palette.rasi";
        expected = palette.toRasi;
      }
    ]}

    export HOME=$TMPDIR
    for theme in ${configs}/themes/*.rasi; do
      if rofi -no-config -theme "$theme" -dump-theme 2>&1 >/dev/null \
           | tee /dev/stderr | grep -q 'Failed to parse theme'; then
        echo
        echo "$(basename "$theme") does not parse."
        echo
        echo "rofi does not fail on this - it warns and loads its own default"
        echo "theme instead, which is why it is checked here."
        exit 1
      fi
    done

    ${geometryScale}/bin/geometry-scale ${configs}/themes/*.rasi

    cp -r ${configs} $out
    chmod -R u+w $out
  '';
in
{
  options.cg.home.rofi.enable = lib.mkEnableOption "Rofi launcher";

  config = lib.mkIf cfg.enable {
    # stylix has a rofi target and it is on, but it only does anything when
    # `programs.rofi.enable` is set, which it is not - the raw xdg.configFile
    # route below is used instead so the files stay portable. Turning it off
    # explicitly says so, rather than leaving two things that could both decide
    # to write ~/.config/rofi and letting the order settle it.
    stylix.targets.rofi.enable = false;

    xdg.configFile."rofi" = {
      source = checkedConfigs;
      recursive = true;
    };

    home.packages = [
      pkgs.rofi

      # Item 7: rofi is the menu system, and this is the shared front door to
      # it - one theme, one interaction model, one place to change how a menu
      # behaves. It is installed here rather than by each menu's own module
      # because "rofi owns every list of things to pick" is this module's
      # responsibility; a menu that reached for its own launcher flags would
      # be a second menu system. See packages/rofi-menu.
      #
      # Its first caller is the project picker (project-launcher pick, bound to
      # SUPER+P and clickable on the bar - the rule that every menu is reachable
      # both ways, already satisfied). Items 8 to 11 and 13 add the rest.
      (pkgs.rofi-menu or (pkgs.callPackage ../../../packages/rofi-menu { }))
    ];
  };
}
