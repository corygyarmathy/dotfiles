# AdGuard Home - Local DNS Server with Ad Blocking
#
# Provides:
# - Local DNS resolution for the fleet's own subdomains
# - Ad and tracker blocking
# - Encrypted DNS (DoH/DoT) upstream
# - Query logging and statistics
#
# Architecture:
# - Primary: the host named by fleet.roles.gateway
# - Secondary: another host running the same config on a different bind address
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
  fleet = config.cg.fleet;
  inherit (fleet) domain;

  # Where the two fleet-wide duties live. Everything below is expressed
  # against these rather than against host names, so moving a duty to another
  # machine is an edit to fleet/default.nix and nothing else.
  gateway = fleet.hosts.${fleet.roles.gateway}.address;
  storage = fleet.hosts.${fleet.roles.storage}.address;

  # Every host that has a reserved address resolves by name. The laptop does
  # not have one, which is why this filters rather than mapping the lot.
  addressed = lib.filterAttrs (_: host: host ? address) fleet.hosts;

  # DNS rewrites for local services.
  #
  # Subdomains are listed by the duty that serves them, not by host name.
  # Add a new service to the list for whichever machine's Caddy fronts it.
  gatewaySubdomains = [
    "jellyfin"
    "requests"
    "invite"
    "sonarr"
    "radarr"
    "autobrr"
    "prowlarr"
    "bazarr"
    "huntarr"
    "cleanuparr"
    "grafana"
    "prometheus"
    "adguard"
    "rss"
    "read"
    "kavita"
    "audiobookshelf"
  ];

  # Services fronted by the storage host's own Caddy.
  #
  # These entries are load-bearing, not documentation. The wildcard at the
  # bottom of the list sends every subdomain that is not named here to the
  # gateway, so a service added to the storage host's reverse proxy without an
  # entry here resolves to a machine whose Caddy has never heard of it. That
  # fails as a TLS error rather than a 404, because Caddy has no certificate
  # for a hostname it does not serve, which points suspicion at the
  # certificate rather than at DNS.
  #
  # A service running on the storage host but proxied *by the gateway* (via
  # the reverse proxy's `upstream` option, as grimmory is) belongs in the list
  # above, not this one.
  storageSubdomains = [
    "downloads"
    "adguard2"
    "filebrowser"
    "shelfmark"
    "suwayomi"
  ];

  mkRewrite = answer: sub: {
    domain = "${sub}.${domain}";
    inherit answer;
  };

  dnsRewrites =
    # Server hostnames
    lib.mapAttrsToList (name: host: mkRewrite host.address name) addressed
    ++ map (mkRewrite gateway) gatewaySubdomains
    ++ map (mkRewrite storage) storageSubdomains
    ++ cfg.extraRewrites # add supplied rewrites
    ++ [
      # Wildcard fallback - routes undefined subdomains to the gateway.
      #
      # The host-alive beacons (`alive-<host>`, see host-alive.nix) are
      # deliberately left to this wildcard rather than listed above: both
      # resolve to the gateway's Caddy, so the peer's reachability probes cross
      # the LAN instead of the public internet. That is a choice about which
      # failure modes item 9 observes, not an accident - see the item 9
      # "Deferred" section in docs/plans/deployment-hardening.md. If the beacons
      # are ever meant to guarantee a public path, they must move out of the
      # wildcard into an explicit Cloudflare-edge rewrite.
      {
        domain = "*.${domain}";
        answer = gateway;
      }
      {
        domain = domain;
        answer = gateway;
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
  # Reads config.cg.fleet and contributes to config.cg.publish, so it declares
  # both - see modules/nixos/fleet.nix and modules/nixos/publish.nix.
  imports = [
    ../nixos/fleet.nix
    ../nixos/publish.nix
  ];

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
        - primary: Main DNS server
        - secondary: Backup DNS server
        Both use identical configuration for failover.
      '';
    };

    bindAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1" ];
      example = [
        "127.0.0.1"
        "10.20.2.85"
      ];
      description = ''
        IP addresses for the DNS server to listen on.
        Avoid 0.0.0.0 if Podman is running (conflicts with aardvark-dns).
      '';
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 3080;
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
    extraRewrites = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            domain = lib.mkOption {
              type = lib.types.str;
              description = "Domain or subdomain to rewrite";
            };
            answer = lib.mkOption {
              type = lib.types.str;
              description = "IP address to resolve to";
            };
          };
        }
      );
      default = [ ];
      description = "Additional DNS rewrites beyond the defaults";
    };
  };

  config = lib.mkIf cfg.enable {
    # The web UI. Both instances run this module, so the hostname is the one
    # part a host has to choose for itself - the secondary answers to
    # `adguard2`, which is the name in the storage host's rewrite list above.
    cg.publish.adguard-home = {
      subdomain = if cfg.role == "primary" then "adguard" else "adguard2";
      port = cfg.webPort;
    };

    # Configure secrets
    sops.secrets."adguard/admin-password" = {
      mode = "0400";
    };

    services.adguardhome = {
      enable = true;

      # Allow changes via web UI to persist
      # Set to false for fully declarative (Nix-only) config
      mutableSettings = false;

      # Open firewall for DNS
      openFirewall = cfg.openFirewall;

      # Web interface port
      port = cfg.webPort;

      # AdGuard Home configuration
      # Reference: https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration
      settings = {
        # HTTP server settings (web interface)
        http = {
          address = "127.0.0.1:${toString cfg.webPort}";
        };

        # Custom filtering rules
        user_rules = [
          # Whitelist SponsorBlock
          "@@||sponsor.ajay.app^"
          "@@||sponsorblock.inf.re^"

          # Whitelist TMDB (The Movie Database) - used by Jellyseerr for metadata
          "@@||api.themoviedb.org^"
          "@@||themoviedb.org^"
          "@@||tmdb.org^"
          "@@||image.tmdb.org^"

          # Whitelist TVDB - used for TV show metadata
          "@@||thetvdb.com^"
          "@@||api.thetvdb.com^"
          "@@||artworks.thetvdb.com^"

          # Whitelist Fanart.tv - additional artwork
          "@@||fanart.tv^"
          "@@||assets.fanart.tv^"

          # Whitelist for poster/image CDNs commonly used
          "@@||image.tmdb.org^"
          "@@||artworks.thetvdb.com^"
        ];

        # DNS server settings
        dns = {
          # Bind to all defined interfaced on port 53
          bind_hosts = cfg.bindAddresses;
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
          ]
          ++ lib.mapAttrsToList (_: host: host.address) addressed;

          # Local PTR resolvers for reverse DNS - the router is the only thing
          # that knows what DHCP handed out.
          local_ptr_upstreams = [
            fleet.lan.gateway
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

          # DNS rewrites for local services
          # This is where the magic happens for local resolution
          rewrites = dnsRewrites;
        };

        # Filter lists
        filters = filterLists;

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
        # The password hash can be generated with:
        #   htpasswd -B -n -b "" "yourpassword" | cut -d: -f2
        #   TODO: inject credentials through sops instead (not a major issue as it's only the hash)
        users = [
          {
            name = "admin";
            password = "$2a$12$u9jRNDNshymgD15iI7tJF.vzzb56MuvWArpucehC46vzgqnQQftJe";
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
