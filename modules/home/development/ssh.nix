# SSH client configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.ssh;
in
{
  options.cg.home.ssh.enable = lib.mkEnableOption "SSH configuration";

  config = lib.mkIf cfg.enable {
    programs.ssh = {
      enable = true;

      # Home Manager's implicit defaults are on their way out; they are spelled
      # out under settings."*" below instead.
      enableDefaultConfig = false;

      # Attribute names become `Host <name>`; the "*" block is always emitted
      # last so the more specific blocks win.
      settings = {
        "gitlab.com github.com" = {
          User = "git";
          ForwardAgent = true;
          IdentitiesOnly = true;
          IdentityFile = [ "~/.ssh/id_github" ];
        };

        "*" = {
          IdentityFile = [ "~/.ssh/id_ed25519_personal" ];
          AddKeysToAgent = "yes";
          ControlMaster = "auto";
          ControlPath = "~/.ssh/sockets/S.%r@%h:%p";
          ControlPersist = "10m";

          # Upstream defaults, kept verbatim now that they are no longer implied.
          ForwardAgent = false;
          Compression = false;
          ServerAliveInterval = 0;
          ServerAliveCountMax = 3;
          HashKnownHosts = false;
          UserKnownHostsFile = "~/.ssh/known_hosts";
        };
      };
    };

    home.file.".ssh/sockets/.keep".text = "# Managed by Home Manager";

    services.ssh-agent.enable = true;
  };
}
