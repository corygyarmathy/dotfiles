# modules/nixos/firewall.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.firewall;
in
{
  options.cg.firewall = {
    enable = lib.mkEnableOption "Firewall configuration";

    allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      example = [
        80
        443
        8080
      ];
      description = "Additional TCP ports to allow";
    };

    allowedUDPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      example = [ 51820 ];
      description = "Additional UDP ports to allow";
    };

    allowedTCPPortRanges = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.port);
      default = [ ];
      example = [
        {
          from = 8000;
          to = 8010;
        }
      ];
      description = "TCP port ranges to allow";
    };

    allowedUDPPortRanges = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.port);
      default = [ ];
      example = [
        {
          from = 27000;
          to = 27050;
        }
      ];
      description = "UDP port ranges to allow (e.g., for gaming)";
    };

    # Presets for common use cases
    presets = {
      ssh = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Allow SSH (port 22)";
      };

      printing = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Allow mDNS for printer/service discovery";
      };

      development = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow common development ports (3000, 4000, 5000, 8000, 8080)";
      };

      syncthing = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow Syncthing ports";
      };

      kdeconnect = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow KDE Connect ports (for phone integration)";
      };
    };

    trustedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "docker0"
        "virbr0"
      ];
      description = "Interfaces to trust completely (all traffic allowed)";
    };

    fail2ban = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable fail2ban for brute force protection";
      };
    };

    hardening = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable extra iptables hardening rules";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall = {
      enable = true;

      # Combine user-specified ports with preset ports
      allowedTCPPorts =
        cfg.allowedTCPPorts
        ++ lib.optionals cfg.presets.ssh [ 22 ]
        ++ lib.optionals cfg.presets.development [
          3000
          4000
          5000
          8000
          8080
        ]
        ++ lib.optionals cfg.presets.syncthing [ 22000 ]
        ++ lib.optionals cfg.presets.kdeconnect (lib.range 1714 1764);

      allowedUDPPorts =
        cfg.allowedUDPPorts
        ++ lib.optionals cfg.presets.printing [ 5353 ]
        ++ lib.optionals cfg.presets.syncthing [
          22000
          21027
        ]
        ++ lib.optionals cfg.presets.kdeconnect (lib.range 1714 1764);

      allowedTCPPortRanges = cfg.allowedTCPPortRanges;
      allowedUDPPortRanges = cfg.allowedUDPPortRanges;

      trustedInterfaces = cfg.trustedInterfaces;

      # Required for some VPNs and Docker
      checkReversePath = "loose";

      # Logging for debugging
      logReversePathDrops = true;
      logRefusedConnections = true;

      # Extra hardening rules
      extraCommands = lib.mkIf cfg.hardening.enable ''
        # Drop invalid packets
        iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
        ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP

        # Drop TCP packets with suspicious flag combinations
        # XMAS packets (all flags set)
        iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
        ip6tables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP

        # NULL packets (no flags set)
        iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
        ip6tables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP

        # SYN-FIN (invalid combination)
        iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
        ip6tables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP

        # SYN-RST (invalid combination)
        iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
        ip6tables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
      '';

      extraStopCommands = lib.mkIf cfg.hardening.enable ''
        iptables -D INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
        ip6tables -D INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
        iptables -D INPUT -p tcp --tcp-flags ALL ALL -j DROP 2>/dev/null || true
        ip6tables -D INPUT -p tcp --tcp-flags ALL ALL -j DROP 2>/dev/null || true
        iptables -D INPUT -p tcp --tcp-flags ALL NONE -j DROP 2>/dev/null || true
        ip6tables -D INPUT -p tcp --tcp-flags ALL NONE -j DROP 2>/dev/null || true
        iptables -D INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP 2>/dev/null || true
        ip6tables -D INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP 2>/dev/null || true
        iptables -D INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP 2>/dev/null || true
        ip6tables -D INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP 2>/dev/null || true
      '';
    };

    # Fail2ban configuration
    services.fail2ban = lib.mkIf cfg.fail2ban.enable {
      enable = true;
      maxretry = 5;
      bantime = "1h";
      bantime-increment = {
        enable = true;
        maxtime = "48h";
        factor = "4";
      };

      jails = {
        sshd = lib.mkIf cfg.presets.ssh {
          settings = {
            enabled = true;
            filter = "sshd";
            maxretry = 3;
            findtime = "10m";
            bantime = "1h";
          };
        };
      };
    };
  };
}
