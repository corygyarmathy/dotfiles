# Waybar status bar
{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.waybar;

  configs = ../../../configs/waybar;

  # Where the bar will actually look for the commands it names. waybar runs as
  # a systemd user service inside the graphical session, so its PATH is the
  # user's own profile plus the system one - the same two closures, not a
  # hand-written list that could disagree with them.
  #
  # `/run/wrappers/bin` is not modelled: nothing on the bar is setuid today,
  # and a wrapper cannot be resolved from inside the build sandbox. A command
  # that needs one will fail this check, which is the right moment to decide
  # whether it belongs on the bar at all.
  searchPath = lib.concatStringsSep ":" [
    "${config.home.path}/bin"
    "${osConfig.system.path}/bin"
    "${osConfig.system.path}/sbin"
  ];

  # Item 1 of docs/plans/desktop-design.md.
  #
  # This is a check, but it is not in `checks/`: it gates the *build* rather
  # than a test run, so a configuration whose bar has a dead button cannot be
  # switched to in the first place - not on this laptop and not in CI, which
  # builds every host. Making the deployed config file the check's output is
  # what buys that: there is no way to ship config.jsonc without the check
  # having passed on it.
  #
  # See ./waybar-commands.py for what it does and does not look at.
  checkedConfigs =
    pkgs.runCommand "waybar-config"
      {
        nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.json5 ])) ];
      }
      ''
        python3 ${./waybar-commands.py} ${configs}/config.jsonc ${lib.escapeShellArg searchPath}

        cp -r ${configs} $out
        chmod -R u+w $out
      '';
in
{
  options.cg.home.waybar.enable = lib.mkEnableOption "Waybar status bar";

  config = lib.mkIf cfg.enable {
    xdg.enable = true;

    systemd.user.services.waybar = {
      Unit = {
        Description = "Waybar";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.waybar}/bin/waybar";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # The bar's system modules open btop, so the bar is what has to carry it.
    # Putting it in the host's package list instead would let the two drift,
    # which is the failure the check above exists to stop.
    home.packages = [ pkgs.btop ];

    # Source external config files for portability
    # These files can be used standalone on non-NixOS systems - what is
    # deployed here is a verbatim copy of ../../../configs/waybar, produced by
    # the derivation that checks it.
    xdg.configFile."waybar" = {
      source = checkedConfigs;
      recursive = true;
    };

    programs.waybar = {
      enable = true;
      # Note: We're using xdg.configFile above instead of the settings/style options
      # This keeps the config portable for non-NixOS systems
    };
  };
}
