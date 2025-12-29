# SSH client configuration
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.home.ssh;
in {
  options.cg.home.ssh.enable = lib.mkEnableOption "SSH configuration";

  config = lib.mkIf cfg.enable {
    programs.ssh = {
      enable = true;
      addKeysToAgent = "yes";

      matchBlocks = {
        git = {
          host = "gitlab.com github.com";
          user = "git";
          forwardAgent = true;
          identitiesOnly = true;
          identityFile = ["~/.ssh/id_github"];
        };
      };

      controlMaster = "auto";
      controlPath = "~/.ssh/sockets/S.%r@%h:%p";
      controlPersist = "10m";
    };

    home.file.".ssh/sockets/.keep".text = "# Managed by Home Manager";

    services.ssh-agent.enable = true;
  };
}
