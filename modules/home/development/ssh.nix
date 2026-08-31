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

        # The two homelab servers, reached by name. `User` is spelled out so a
        # plain `ssh homelab01` works from the laptop; deploy-rs passes its own
        # `sshUser` on the command line, which overrides it.
        "homelab01 homelab02" = {
          User = "coryg";
        };

        # deploy-rs connects as `deploy@…` (item 10 of the hardening plan) and
        # that account only accepts its own key, not the human's. Offer only
        # the dedicated deploy key on those connections so the personal key is
        # never presented to the deploy account.
        "deploy@homelab01 deploy@homelab02" = {
          User = "deploy";
          IdentitiesOnly = true;
          IdentityFile = [ "~/.ssh/deploy" ];
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
