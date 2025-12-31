# modules/nixos/ssh-hardening.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.ssh-hardening;
in
{
  options.cg.ssh-hardening = {
    enable = lib.mkEnableOption "SSH hardening";

    permitRootLogin = lib.mkOption {
      type = lib.types.enum [
        "no"
        "prohibit-password"
        "forced-commands-only"
        "yes"
      ];
      default = "no";
      description = "Whether root can login via SSH";
    };

    passwordAuthentication = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow password authentication (discouraged)";
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "coryg" ];
      description = "Users allowed to SSH in";
    };

    ports = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 22 ];
      description = "Ports to listen on";
    };

    allowAgentForwarding = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow SSH agent forwarding (needed for jumping through this host)";
    };

    allowTcpForwarding = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow TCP forwarding/tunneling";
    };

    trustedNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "192.168.1.0/24"
        "10.0.0.0/8"
      ];
      description = "Networks to allow SSH from (empty = all)";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAA... user@host" ];
      description = "Additional SSH public keys to authorize for coryg";
    };
  };

  config = lib.mkIf cfg.enable {
    services.openssh = {
      enable = true;
      ports = cfg.ports;

      # Only use Ed25519 host keys (most secure)
      hostKeys = [
        {
          path = "/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];

      settings = {
        # Authentication
        PasswordAuthentication = cfg.passwordAuthentication;
        PermitEmptyPasswords = false;
        PermitRootLogin = cfg.permitRootLogin;
        AllowUsers = cfg.allowedUsers;

        # Force public key authentication
        PubkeyAuthentication = true;
        AuthenticationMethods =
          if cfg.passwordAuthentication then
            "publickey,password publickey" # Key OR password
          else
            "publickey"; # Key only

        # Disable legacy/weak authentication
        ChallengeResponseAuthentication = false;
        HostbasedAuthentication = false;
        KbdInteractiveAuthentication = false;

        # Strong algorithms only
        KexAlgorithms = [
          "sntrup761x25519-sha512@openssh.com" # Post-quantum hybrid
          "curve25519-sha256"
          "curve25519-sha256@libssh.org"
          "diffie-hellman-group16-sha512"
          "diffie-hellman-group18-sha512"
        ];

        Ciphers = [
          "chacha20-poly1305@openssh.com"
          "aes256-gcm@openssh.com"
          "aes128-gcm@openssh.com"
        ];

        Macs = [
          "hmac-sha2-512-etm@openssh.com"
          "hmac-sha2-256-etm@openssh.com"
        ];

        # Forwarding settings
        X11Forwarding = false;
        AllowTcpForwarding = cfg.allowTcpForwarding;
        AllowAgentForwarding = cfg.allowAgentForwarding;
        AllowStreamLocalForwarding = false;
        GatewayPorts = null;
        PermitTunnel = false;

        # Session limits
        ClientAliveInterval = 300;
        ClientAliveCountMax = 2;
        LoginGraceTime = 30;
        MaxAuthTries = 3;
        MaxSessions = 3;
        MaxStartups = "3:50:10"; # start:rate:full - rate limit connections

        # Security
        StrictModes = true;
        UseDns = false; # Prevent DNS-based attacks/delays

        # Logging
        LogLevel = "VERBOSE";
      };

      # Restrict to specific networks if configured
      listenAddresses = lib.mkIf (cfg.trustedNetworks != [ ]) (
        map (net: { addr = net; }) cfg.trustedNetworks
      );
    };

    # Add authorized keys for the user
    users.users.coryg.openssh.authorizedKeys.keys = cfg.authorizedKeys;

    # Ensure SSH directory has correct permissions
    systemd.tmpfiles.rules = [
      "d /home/coryg/.ssh 0700 coryg users -"
    ];
  };
}
