# Hyprland - Home-manager configuration
# Updated for Hyprland 0.55+ (Lua config)
{
  inputs,
  config,
  osConfig,
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

  # Where the binds' commands will actually be found. Hyprland runs inside the
  # graphical session, so its PATH is the user's profile plus the system one -
  # the same two closures, read from the evaluated configuration rather than
  # restated, exactly as waybar.nix does for the bar. See ./lib/session-path.nix.
  searchPath = import ./lib/session-path.nix { inherit lib config osConfig; };

  # The keybind sheet's parser, as the build-gate command. Same resolution the
  # keybind-sheet module uses: the overlay's package, or the source on its own.
  # See ../../../packages/keybind-sheet.
  keybind-sheet = pkgs.keybind-sheet or (pkgs.callPackage ../../../packages/keybind-sheet { });

  # Item 1's extension, taken with items 8-15. binds.lua names binaries in
  # its exec_cmd strings and no check covered them; a bind that runs nothing
  # is the bar's dead click wearing a keyboard. See ./binds-commands.py.
  #
  # The same runCommand also gates item 11's keybind sheet: the parser reads
  # the *deployed* binds.lua at runtime, and keybind-sheet-parse - the
  # package's own command - runs the identical parser over the checked-in
  # file so a binds.lua the sheet stops understanding fails the build instead
  # of silently losing its documentation.
  checkedBinds = pkgs.runCommand "hypr-binds.lua" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${./binds-commands.py} ${configs}/binds.lua ${lib.escapeShellArg searchPath}
    ${keybind-sheet}/bin/keybind-sheet-parse ${configs}/binds.lua > /dev/null
    cp ${configs}/binds.lua $out
  '';

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
      "hypr/binds.lua".source = checkedBinds;
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
