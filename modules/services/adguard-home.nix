# AdGuard Home - Local DNS Server with Ad Blocking
#
# Provides:
# - Local DNS resolution for *.gyarmathy.co services
# - Ad and tracker blocking
# - Encrypted DNS (DoH/DoT) upstream
# - Query logging and statistics
#
# Architecture:
# - Primary: homelab01 (10.20.2.85)
# - Secondary: homelab02 (10.20.2.130) - same config, different bind address
#
# Usage:
#   cg.service.adguard-home = {
#     enable = true;
#     role = "primary";  # or "secondary"
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.adguard-home;

  # Domain configuration - centralised for easy updates
  domain = "gyarmathy.co";

  # Server IPs - used for DNS rewrites
  servers = {
    homelab01 = "10.20.2.85";
    homelab02 = "10.20.2.130";
  };

  # The server that runs the reverse proxy (where services are accessed)
  primaryServer = servers.homelab01;

  # DNS rewrites for local services
  # These map subdomains to the reverse proxy server
  # Add new services here as you deploy them
  dnsRewrites = [
    # Wildcard for all subdomains - simplest approach
    # This means ANY subdomain resolves to the primary server
    # Caddy will handle returning 404 for undefined services
    {
      domain = "*.${domain}";
      answer = primaryServer;
    }
    # Base domain (if you want gyarmathy.co itself to resolve locally)
    {
      domain = domain;
      answer = primaryServer;
    }
  ];

  # Upstream DNS servers - using encrypted DNS
  # These are queried for external domains (anything not in rewrites)
  upstreamDns = [
    # Quad9 - privacy-focused, malware blocking
    "https://dns.quad9.net/dns-query"
    # Cloudflare - fast, privacy-focused
    "https://cloudflare-dns.com/dns-query"
    # Backup: Google (commented out - less private but very reliable)
    # "https://dns.google/dns-query"
  ];

  # Bootstrap DNS - used to resolve the DoH server hostnames initially
  # Must be plain IP addresses
  bootstrapDns = [
    "9.9.9.9"
    "149.112.112.112"
    "1.1.1.1"
    "1.0.0.1"
  ];

  # Ad blocking filter lists
  # You can add more from: https://adguardteam.github.io/HostlistsRegistry/
  filterLists = [
    {
      enabled = true;
      name = "AdGuard DNS filter";
      url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
      id = 1;
    }
    {
      enabled = true;
      name = "AdAway Default Blocklist";
      url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
      id = 2;
    }
    {
      enabled = true;
      name = "HaGeZi's Pro Blocklist";
      url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_48.txt";
      id = 3;
    }
    {
      enabled = true;
      name = "OISD Blocklist Small";
      url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_5.txt";
      id = 4;
    }
    {
      enabled = true;
      name = "The Big List of Hacked Malware Web Sites";
      url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt";
      id = 5;
    }
    {
      enabled = true;
      name = "Malicious URL Blocklist";
      url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt";
      id = 6;
    }
    {
      enabled = true;
      name = "Phishing URL Blocklist";
      url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt";
      id = 7;
    }
  ];

in
{
  options.cg.service.adguard-home = {
    enable = lib.mkEnableOption "AdGuard Home DNS server";

    role = lib.mkOption {
      type = lib.types.enum [
        "primary"
        "secondary"
      ];
      default = "primary";
      description = ''
        Role of this AdGuard Home instance.
        - primary: Main DNS server (homelab01)
        - secondary: Backup DNS server (homelab02)
        Both use identical configuration for failover.
      '';
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port for the AdGuard Home web interface";
    };

    dnsPort = lib.mkOption {
      type = lib.types.port;
      default = 53;
      description = "Port for DNS queries";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to open firewall ports for DNS and web interface";
    };
  };

  config = lib.mkIf cfg.enable {
    # Configure secrets
    sops.secrets."adguard/admin-password" = {
      sopsFile = ../../secrets/homelab.yaml;
      mode = "0400";
    };

    services.adguardhome = {
      enable = true;

      # Allow changes via web UI to persist
      # Set to false for fully declarative (Nix-only) config
      mutableSettings = true;

      # Open firewall for DNS
      openFirewall = cfg.openFirewall;

      # Web interface port
      port = cfg.webPort;

      # AdGuard Home configuration
      # Reference: https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration
      settings = {
        # HTTP server settings (web interface)
        http = {
          address = "0.0.0.0:${toString cfg.webPort}";
        };

        # DNS server settings
        dns = {
          # Bind to all interfaces on port 53
          bind_hosts = [ "0.0.0.0" ];
          port = cfg.dnsPort;

          # Upstream DNS servers (encrypted)
          upstream_dns = upstreamDns;

          # Bootstrap DNS for initial DoH resolution
          bootstrap_dns = bootstrapDns;

          # Use parallel queries to all upstreams, take fastest
          upstream_mode = "parallel";

          # Enable DNSSEC validation
          enable_dnssec = true;

          # Cache settings
          cache_size = 10000000; # 10MB cache
          cache_ttl_min = 300; # Minimum 5 minutes
          cache_ttl_max = 86400; # Maximum 24 hours
          cache_optimistic = true; # Serve stale while refreshing

          # Rate limiting (protection against DNS amplification)
          ratelimit = 100; # queries per second per client
          ratelimit_whitelist = [
            "127.0.0.1"
          ];

          # Local PTR resolvers for reverse DNS
          local_ptr_upstreams = [
            "10.20.2.1" # Your router for local reverse lookups
          ];
          use_private_ptr_resolvers = true;

          # Blocking mode - return 0.0.0.0 for blocked domains
          blocking_mode = "default";

          # EDNS Client Subnet - disable for privacy
          edns_client_subnet = {
            enabled = false;
          };
        };

        # Filtering settings
        filtering = {
          protection_enabled = true;
          filtering_enabled = true;

          # Parental controls - disable unless needed
          parental_enabled = false;

          # Safe search enforcement - disable unless needed
          safe_search = {
            enabled = false;
          };

          # Block domains after this many seconds of filtering lag
          blocking_ipv4 = "0.0.0.0";
          blocking_ipv6 = "::";

          # How long to cache filtered results
          filters_update_interval = 24; # hours
        };

        # Filter lists
        filters = filterLists;

        # DNS rewrites for local services
        # This is where the magic happens for local resolution
        rewrites = dnsRewrites;

        # Query log settings
        querylog = {
          enabled = true;
          file_enabled = true;
          interval = "24h"; # Rotation interval
          size_memory = 1000; # Entries to keep in memory
          ignored = [ ]; # Domains to not log
        };

        # Statistics
        statistics = {
          enabled = true;
          interval = "24h"; # Stats retention
          ignored = [ ]; # Domains to exclude from stats
        };

        # User authentication for web interface
        # NOTE: This is a placeholder - you should set this via the web UI
        # on first run, or use sops-nix to inject credentials
        # The password hash can be generated with:
        #   htpasswd -B -n -b "" "yourpassword" | cut -d: -f2
        users = [
          {
            name = "admin";
            # This is a placeholder - CHANGE THIS on first login!
            # Default: admin/admin (you'll be prompted to change it)
            password = "$2y$10$hWqpOAVLrSrVBqXKQYGfE.yLWvSYZoL6rSfVBqXKQYGfE.yLWvSY";
          }
        ];

        # Schema version (don't change unless upgrading)
        schema_version = 29;
      };
    };

    # Additional firewall rules
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        cfg.dnsPort # DNS over TCP
        cfg.webPort # Web interface
      ];
      allowedUDPPorts = [
        cfg.dnsPort # DNS over UDP (primary)
      ];
    };

    # Ensure AdGuard Home starts after network is up
    systemd.services.adguardhome = {
      after = [
        "network-online.target"
      ];
      wants = [
        "network-online.target"
      ];
    };
  };
}
