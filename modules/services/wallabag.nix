# Wallabag - Self-hosted Read Later
#
# Provides:
# - Save-for-later reading with full article extraction
# - Native Miniflux integration (save articles directly from feed reader)
# - Browser extensions for one-click saving (Firefox/Chrome)
# - Mobile apps (iOS/Android) with share sheet support
# - Article annotations and tagging
#
# Architecture:
# - Wallabag runs as an OCI container (official wallabag/wallabag image)
# - PostgreSQL database managed locally, shared server with Miniflux
# - Exposed via Caddy reverse proxy at read.gyarmathy.co
#
# Non-obvious implementation notes:
# - There is no upstream services.wallabag NixOS module in nixpkgs; community
#   modules exist but are fragile PHP/phpfpm setups. The official Docker image
#   is the recommended and most reliable deployment method.
# - Podman containers reach the host via the default bridge gateway at
#   10.88.0.1. PostgreSQL must listen on this interface and permit connections
#   from the 10.88.0.0/16 subnet for the container to connect.
# - POPULATE_DATABASE=true is safe to leave enabled on all boots; Wallabag
#   checks whether the schema already exists before running migrations.
# - The app secret must be stable across restarts — never regenerate it on a
#   live instance as this invalidates all existing user sessions.
# - The OCI container service is named podman-wallabag.service by NixOS.
# - The environmentFiles option passes secrets via --env-file to the Podman
#   runtime (not into the container filesystem), so root ownership is correct.
#
# Post-deploy setup:
#   1. Navigate to https://read.gyarmathy.co and log in (wallabag/wallabag)
#   2. IMMEDIATELY change the default password under Settings → My Account
#   3. In Miniflux: Settings → Integrations → Wallabag
#      Set URL to https://read.gyarmathy.co, enter your credentials
#   4. Browser extension:
#      Firefox: https://addons.mozilla.org/en-US/firefox/addon/wallabagger/
#      Chrome:  https://chromewebstore.google.com/detail/wallabagger
#   5. Mobile: search "wallabag" in App Store or Play Store
#
# Secrets required in secrets/homelab.yaml:
#   wallabag/db-password: <password>
#   wallabag/app-secret: <random string — generate with: openssl rand -hex 32>
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.wallabag;
in
{
  options.cg.service.wallabag = {
    enable = lib.mkEnableOption "Wallabag read-it-later service";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8083;
      description = "Host port Wallabag listens on (localhost only)";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://read.gyarmathy.co";
      description = "Public base URL for Wallabag (must match SYMFONY__ENV__DOMAIN_NAME)";
    };
  };

  config = lib.mkIf cfg.enable {
    sops = {
      # Database password — group-owned by postgres so wallabag-db-setup can
      # read it while running as the postgres OS user (peer auth on local socket).
      secrets."wallabag/db-password" = {
        sopsFile = ../../secrets/homelab.yaml;
        owner = "root";
        group = "postgres";
        mode = "0440";
      };

      # App secret — used by Symfony for session tokens and CSRF protection.
      # Must remain stable; changing it invalidates all active sessions.
      secrets."wallabag/app-secret" = {
        sopsFile = ../../secrets/homelab.yaml;
        mode = "0400";
      };

      # Environment file injected into the Wallabag container at runtime.
      # Interpolates secrets at activation time so they never touch the Nix store.
      templates."wallabag-env" = {
        content = ''
          SYMFONY__ENV__DATABASE_DRIVER=pdo_pgsql
          SYMFONY__ENV__DATABASE_HOST=10.88.0.1
          SYMFONY__ENV__DATABASE_PORT=5432
          SYMFONY__ENV__DATABASE_NAME=wallabag
          SYMFONY__ENV__DATABASE_USER=wallabag
          SYMFONY__ENV__DATABASE_PASSWORD=${config.sops.placeholder."wallabag/db-password"}
          SYMFONY__ENV__DOMAIN_NAME=${cfg.baseUrl}
          SYMFONY__ENV__SERVER_NAME=Wallabag
          SYMFONY__ENV__FOSUSER_REGISTRATION=false
          SYMFONY__ENV__FOSUSER_CONFIRMATION=false
          SYMFONY__ENV__SECRET=${config.sops.placeholder."wallabag/app-secret"}
          POPULATE_DATABASE=true
        '';
        mode = "0400";
        restartUnits = [ "podman-wallabag.service" ];
      };
    };

    # Trust the Podman bridge interface so the container can reach host services
    # (PostgreSQL at 10.88.0.1). podman0 is a local virtual bridge — nothing
    # external can inject traffic onto it, so trusting it fully is safe.
    networking.firewall.trustedInterfaces = [ "podman0" ];

    # PostgreSQL must listen on the Podman bridge interface so the container
    # can connect. The default bridge gateway (10.88.0.1) is the host address
    # reachable from the default Podman network (10.88.0.0/16).
    services.postgresql.settings.listen_addresses = lib.mkForce "127.0.0.1,10.88.0.1";

    # Allow the wallabag role to connect from the Podman container network.
    # md5 matches the authentication method used for other TCP connections
    # (consistent with the Miniflux setup).
    services.postgresql.authentication = lib.mkAfter ''
      # Wallabag OCI container (Podman default bridge network)
      host wallabag wallabag 10.88.0.0/16 md5
    '';

    # Oneshot that runs before wallabag on every boot:
    # - Creates the wallabag PostgreSQL role if it does not yet exist
    # - Sets the role password to match the sops secret
    # - Creates the wallabag database if it does not yet exist
    # Runs as the postgres OS user for peer auth on the local socket.
    systemd.services.wallabag-db-setup = {
      description = "Wallabag PostgreSQL setup (role + database)";
      after = [ "postgresql.service" ];
      wants = [ "postgresql.service" ];
      before = [ "podman-wallabag.service" ];
      wantedBy = [ "podman-wallabag.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        ExecStart = pkgs.writeShellScript "wallabag-db-setup" ''
          PASSWORD=$(cat ${config.sops.secrets."wallabag/db-password".path})

          # Create the role if it does not already exist
          ${pkgs.postgresql}/bin/psql -d postgres -c "
            DO \$\$ BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'wallabag') THEN
                CREATE ROLE wallabag WITH LOGIN;
              END IF;
            END \$\$;
          "

          # Always sync the password to match the sops secret
          ${pkgs.postgresql}/bin/psql -d postgres \
            -c "ALTER ROLE wallabag WITH PASSWORD '$PASSWORD';"

          # Create the database if it does not already exist
          DB_EXISTS=$(${pkgs.postgresql}/bin/psql -d postgres -tAc \
            "SELECT 1 FROM pg_database WHERE datname = 'wallabag'")
          if [ "$DB_EXISTS" != "1" ]; then
            ${pkgs.postgresql}/bin/psql -d postgres \
              -c "CREATE DATABASE wallabag OWNER wallabag;"
          fi
        '';
      };
    };

    # Wallabag OCI container (official image, rootful Podman)
    # The container image handles schema installation and migrations
    # automatically on startup via POPULATE_DATABASE=true.
    virtualisation.oci-containers.containers.wallabag = {
      image = "wallabag/wallabag:latest";

      # Bind to localhost only — Caddy terminates TLS externally
      ports = [ "127.0.0.1:${toString cfg.port}:80" ];

      # Secrets injected via --env-file (read by Podman runtime, not container)
      environmentFiles = [ config.sops.templates."wallabag-env".path ];

      # Persist uploaded images and article assets across container restarts
      volumes = [
        "wallabag-images:/var/www/wallabag/web/assets/images"
      ];

    };
  };
}
