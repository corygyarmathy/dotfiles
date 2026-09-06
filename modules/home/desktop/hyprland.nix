# Hyprland - Home-manager configuration
# Updated for Hyprland 0.55+ (Lua config)
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.hyprland;

  configs = ../../../configs/hypr;

  # Item 6 of docs/plans/desktop-design.md. settings.lua is deployed verbatim
  # so it keeps working on a machine without Nix, which means it cannot read
  # the geometry scale - so the build reads it instead. Gaps, border width and
  # window rounding are the compositor's half of the same four numbers waybar,
  # rofi and dunst use. See ./lib/scale.nix.
  geometryScale = import ./lib/scale.nix { inherit pkgs; };

  checkedSettings = pkgs.runCommand "hypr-settings.lua" { } ''
    ${geometryScale}/bin/geometry-scale ${configs}/settings.lua
    cp ${configs}/settings.lua $out
  '';
in
{
  options.cg.home.hyprland.enable = lib.mkEnableOption "Hyprland home configuration";

  config = lib.mkIf cfg.enable {
    # Deploy the Lua config files to ~/.config/hypr/
    # Hyprland 0.55+ loads hyprland.lua instead of hyprland.conf
    xdg.configFile = {
      "hypr/hyprland.lua".source = ../../../configs/hypr/hyprland.lua;
      "hypr/env.lua".source = ../../../configs/hypr/env.lua;
      "hypr/monitors.lua".source = ../../../configs/hypr/monitors.lua;
      "hypr/settings.lua".source = checkedSettings;
      "hypr/animations.lua".source = ../../../configs/hypr/animations.lua;
      "hypr/rules.lua".source = ../../../configs/hypr/rules.lua;
      "hypr/binds.lua".source = ../../../configs/hypr/binds.lua;
      "hypr/autostart.lua".source = ../../../configs/hypr/autostart.lua;
    };

    wayland.windowManager.hyprland = {
      enable = true;
      systemd = {
        enable = true;
        variables = [ "--all" ]; # Import all env vars including PATH
      };
    };

    # The other half of `security.polkit.enable` in modules/nixos/hyprland.nix.
    # That option starts polkitd, which is the half that *decides*; this is the
    # half that *asks*. Without an agent a graphical action needing
    # authorisation has nowhere to prompt, so it fails with no dialog and no
    # visible error - the action simply does not happen.
    #
    # Not behind its own toggle: a session with no way to authenticate is not a
    # configuration anyone would choose, so this is part of what it costs to run
    # Hyprland rather than something to enable separately.
    #
    # Its dialog is Qt and stylix's GTK target does not reach it. Accepted:
    # it should be seen rarely, and polkit-gnome is unmaintained.
    services.hyprpolkitagent.enable = true;

    home.packages = with pkgs; [
      # Screenshots
      grim # Screenshot utility
      slurp # Region selection
      wl-clipboard # Clipboard support
      grimblast # Helper for Hyprland screenshots

      # Hypr Utils
      hyprsysteminfo # System info util
    ];
  };
}
