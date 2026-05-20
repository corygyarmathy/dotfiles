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
in
{
  options.cg.stylix.enable = lib.mkEnableOption "Stylix theming";

  config = lib.mkIf cfg.enable (
    if stylixAvailable then
      {
        stylix = {
          enable = true;
          autoEnable = true; # Enables stylix themes for all applications
          base16Scheme = "${pkgs.base16-schemes}/share/themes/kanagawa.yaml";
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
          base16-schemes # Imports colours schemes. Used for RICEing with Stylix.
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
