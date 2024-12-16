{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.stylix.enable = lib.mkEnableOption "enables stylix";
  };

  config = lib.mkIf config.cg.stylix.enable {
    # RICE settings
    stylix = {
      enable = true;
      autoEnable = true; # Enables stylix themes for all applications
      base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";
      polarity = "dark"; # "light" or "either" - sets light or dark mode
      image = ../../../wallpapers/wallhaven-1h3u9zr.jpg; # Sets wallpaper, ""s are not required for path

      # TODO: replace with catppuccin cursor
      cursor = {
        package = pkgs.rose-pine-cursor;
        name = "BreezeX-RosePine-Linux";
        size = 28;
      };

      # TODO: Investigate new fonts
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
          package = pkgs.noto-fonts-emoji;
          name = "Noto Color Emoji";
        };

        sizes = {
          terminal = 12;
        };
      };
    };
    environment.systemPackages = with pkgs; [
      base16-schemes # Imports colours schemes. Used for RICEing with Stylix.
      bibata-cursors # Imports cursors
      rose-pine-cursor
    ];
    fonts.packages = with pkgs; [
      # dejavu_fonts # Fonts
      noto-fonts
      noto-fonts-emoji # Fonts
      hack-font
      nerd-fonts.hack
      # pixel-code
      # gohufont
      # nerd-fonts.gohufont
    ];
  };
}
