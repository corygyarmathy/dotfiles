# Stylix theming
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.cg.stylix;
  stylixAvailable = lib.hasAttr "stylix" options;

  # Item 5 of docs/plans/desktop-design.md: one palette, one source, and this
  # is the source. It used to be `${pkgs.base16-schemes}/share/themes/
  # kanagawa.yaml`, which is a sixteen-slot reduction of Kanagawa Wave - eight
  # of the colours the bar, the launcher and the calendar actually render have
  # no slot in it, so they were hand-transcribed in four other files instead.
  # `palette.scheme` is byte-identical to that YAML; what changed is that the
  # colours outside it now come from the same place, and that upstream can no
  # longer move the palette under this machine.
  palette = import ../../lib/kanagawa-wave.nix { inherit lib; };
in
{
  options.cg.stylix.enable = lib.mkEnableOption "Stylix theming";

  config = lib.mkIf cfg.enable (
    if stylixAvailable then
      {
        stylix = {
          enable = true;
          autoEnable = true; # Enables stylix themes for all applications
          base16Scheme = palette.scheme;
          polarity = "dark"; # "light" or "either" - sets light or dark mode
          image = ../../wallpapers/wallhaven-6l5emq.png; # Sets wallpaper, ""s are not required for path

          cursor = {
            package = pkgs.rose-pine-cursor;
            name = "BreezeX-RosePine-Linux";
            size = 28;
          };

          # NOTE: to figure out the name of each font, use the command: fc-list
          fonts = {
            serif = {
              package = pkgs.noto-fonts;
              name = "Noto Serif";
            };
            sansSerif = {
              package = pkgs.noto-fonts;
              name = "Noto Sans";
            };
            monospace = {
              package = pkgs.hack-font;
              name = "Hack Nerd Font";
            };
            emoji = {
              package = pkgs.noto-fonts-color-emoji;
              name = "Noto Color Emoji";
            };
            sizes.terminal = 12;
          };
        };

        environment.systemPackages = with pkgs; [
          # A browsable collection of base16 schemes. It is no longer where this
          # machine's palette comes from - see `palette` above - but it is still
          # the reference to reach for when picking a different one.
          base16-schemes
          bibata-cursors
          rose-pine-cursor
        ];

        fonts.packages = with pkgs; [
          noto-fonts
          noto-fonts-color-emoji
          hack-font
          nerd-fonts.hack
        ];
      }
    else
      { }
  );
}
