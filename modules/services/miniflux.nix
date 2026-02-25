# Miniflux - Minimalist RSS Reader
#
# Provides:
# - Self-hosted RSS feed aggregator and reader
# - Single Go binary backed by PostgreSQL
# - Web UI + Fever/Google Reader API for mobile clients (Reeder, NetNewsWire, etc.)
#
# Architecture:
# - Miniflux service runs on localhost, exposed via Caddy reverse proxy
# - PostgreSQL database managed locally via createDatabaseLocally
# - Admin credentials stored in sops
#
# Non-obvious implementation notes:
# - The upstream module sets PrivateUsers=true, which remaps UIDs in a user
#   namespace and breaks Unix socket peer auth with PostgreSQL. We force TCP
#   via DATABASE_URL instead.
# - The generated pg_hba.conf uses md5 for TCP, so the miniflux role needs a
#   real password. We set it via a oneshot service that runs before miniflux.
# - The db-setup service runs as the 'postgres' OS user (required for peer
#   auth on the local socket), so the db-password secret must be group-owned
#   by 'postgres' with mode 0440 so it can be read.
# - DATABASE_URL is injected via a sops template EnvironmentFile to keep the
#   password out of the Nix store.
# - RUN_MIGRATIONS must be an integer, not a string (upstream module type changed).
#
# Mobile clients:
# - Enable the Fever or Google Reader API in Miniflux Settings > Integrations
# - Connect Reeder / NetNewsWire to https://rss.gyarmathy.co
#
# Secrets required in secrets/homelab.yaml:
#   miniflux/admin-credentials: |
#     ADMIN_USERNAME=admin
#     ADMIN_PASSWORD=<password>
#   miniflux/db-password: <password>
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.miniflux;
in
{
  options.cg.service.miniflux = {
    enable = lib.mkEnableOption "Miniflux RSS reader";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = "Port Miniflux listens on (localhost only)";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://rss.gyarmathy.co";
      description = "Public base URL for Miniflux (used in feed links and API responses)";
    };
  };

  config = lib.mkIf cfg.enable {
    sops = {
      # Admin credentials EnvironmentFile: ADMIN_USERNAME and ADMIN_PASSWORD
      # Owned by root — systemd reads EnvironmentFile as root before dropping
      # privileges, so the miniflux user doesn't need direct access.
      secrets."miniflux/admin-credentials" = {
        sopsFile = ../../secrets/homelab.yaml;
        mode = "0400";
        restartUnits = [ "miniflux.service" ];
      };

      # Database password — group-owned by postgres so miniflux-db-setup can
      # read it while running as the postgres OS user (required for peer auth).
      secrets."miniflux/db-password" = {
        sopsFile = ../../secrets/homelab.yaml;
        owner = "root";
        group = "postgres";
        mode = "0440";
      };

      # Rendered env file with DATABASE_URL interpolated at activation time.
      # Keeps the password out of the Nix store.
      templates."miniflux-env" = {
        content = ''
          DATABASE_URL=postgresql://miniflux:${
            config.sops.placeholder."miniflux/db-password"
          }@127.0.0.1/miniflux?sslmode=disable
        '';
        mode = "0400";
        restartUnits = [ "miniflux.service" ];
      };
    };

    # Oneshot that runs before miniflux on every boot:
    # - Creates the hstore extension (required by miniflux migrations)
    # - Sets the miniflux role password to match the sops secret
    # Runs as postgres OS user for peer auth on the local socket.
    systemd.services.miniflux-db-setup = {
      description = "Miniflux PostgreSQL setup (hstore extension + role password)";
      after = [ "postgresql.service" ];
      wants = [ "postgresql.service" ];
      before = [ "miniflux.service" ];
      wantedBy = [ "miniflux.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        ExecStart = pkgs.writeShellScript "miniflux-db-setup" ''
          PASSWORD=$(cat ${config.sops.secrets."miniflux/db-password".path})
          ${pkgs.postgresql}/bin/psql -d miniflux \
            -c "CREATE EXTENSION IF NOT EXISTS hstore;"
          ${pkgs.postgresql}/bin/psql -d postgres \
            -c "ALTER ROLE miniflux WITH PASSWORD '$PASSWORD';"
        '';
      };
    };

    services.miniflux = {
      enable = true;
      createDatabaseLocally = true;
      adminCredentialsFile = config.sops.secrets."miniflux/admin-credentials".path;

      config = {
        LISTEN_ADDR = "127.0.0.1:${toString cfg.port}";
        BASE_URL = cfg.baseUrl;
        # DATABASE_URL injected via sops template EnvironmentFile below

        # Integer required — upstream module type is 'signed integer or boolean'
        RUN_MIGRATIONS = 1;

        POLLING_FREQUENCY = 30;
        POLLING_PARSING_ERROR_LIMIT = 3;
        WORKER_POOL_SIZE = 5;

        CLEANUP_FREQUENCY_HOURS = 24;
        CLEANUP_KEEP_SESSION_DAYS = 90;
      };
    };

    # Inject DATABASE_URL (with password) and admin credentials via EnvironmentFile.
    # The upstream module sets its own EnvironmentFile for admin credentials, but
    # we override here to also include the rendered DATABASE_URL template.
    # Tell the miniflux service to not use sd_notify at all, by changing the startup
    # type from notify to simple.
    systemd.services.miniflux.serviceConfig = {
      Type = lib.mkForce "simple";
      NotifyAccess = lib.mkForce "none";
      EnvironmentFile = lib.mkForce [
        config.sops.secrets."miniflux/admin-credentials".path
        config.sops.templates."miniflux-env".path
      ];
    };
  };
}
