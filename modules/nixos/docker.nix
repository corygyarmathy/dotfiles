# modules/nixos/docker.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.docker;
in
{
  options.cg.docker.enable = lib.mkEnableOption "Enables and configures docker";

  config = lib.mkIf cfg.enable {
    # In your host default.nix or a separate module
    virtualisation.docker = {
      enable = true;

      # Run rootless if possible (may require config changes)
      # rootless.enable = true;

      # Enable live-restore (containers survive daemon restart)
      liveRestore = true;

      # Daemon configuration
      daemon.settings = {
        # Enable user namespace remapping
        "userns-remap" = "default";

        # Disable legacy registry
        "disable-legacy-registry" = true;

        # Enable content trust
        "content-trust" = true;

        # Logging limits
        "log-driver" = "json-file";
        "log-opts" = {
          "max-size" = "10m";
          "max-file" = "3";
        };

        # Disable inter-container communication by default
        "icc" = false;

        # Enable seccomp
        "seccomp-profile" = ""; # Uses default profile
      };
    };
  };
}
