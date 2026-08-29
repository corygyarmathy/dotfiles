# Vikunja - Self-hosted To-do & Task Manager
#
# Provides:
# - Full-stack task manager (Go backend + bundled frontend)
# - Web UI accessible at tasks.gyarmathy.co
# - CalDAV endpoint for mobile clients (tasks.org, etc.)
#
# Architecture:
# - Vikunja service runs on localhost, exposed via Caddy reverse proxy
# - PostgreSQL database managed locally (reuses existing PG instance)
# - JWT secret stored in sops; no DB password needed (peer auth via socket)
#
# Non-obvious implementation notes:
# - The upstream services.vikunja module does NOT have database.createLocally.
#   We wire PostgreSQL manually via services.postgresql.ensureUsers /
#   ensureDatabases, which is what the PG module intends for this pattern.
# - The upstream module uses DynamicUser=true (systemd allocates the "vikunja"
#   OS user at runtime). NixOS peer auth matches by OS username, so Vikunja
#   can connect to the "vikunja" PG role via the Unix socket with no password.
# - We therefore set database.host to the socket directory (/run/postgresql)
#   and omit any password — unlike miniflux which needs TCP + md5 auth due
#   to its own PrivateUsers isolation breaking socket peer auth.
# - The JWT secret is the only secret needed; it's injected via a sops
#   EnvironmentFile (VIKUNJA_SERVICE_JWTSECRET) so it never hits the Nix store.
# - frontendScheme = "https" and frontendHostname = public domain tell Vikunja
#   what to put in outgoing links and CORS headers. Caddy terminates TLS;
#   the backend only listens on localhost HTTP.
# - The upstream module does not configure caddy/nginx — wired via the
#   existing cg.service.reverse-proxy module in homelab01.nix.
#
# Secrets required (which file they live in is decided by cg.sops-nix; see
# secrets/README.md):
#   vikunja/jwt-secret: <random-string>
#     Generate with: openssl rand -hex 32
#
# First-run checklist:
#   1. Visit https://tasks.gyarmathy.co — you'll be prompted to create an admin account
#   2. Once your account exists, flip settings.service.enableregistration = false and rebuild
#
{
  config,
  lib,
  ...
}:
let
  cfg = config.cg.service.vikunja;
in
{
  # Reads config.cg.fleet, so it declares it - see modules/nixos/fleet.nix.
  imports = [ ../nixos/fleet.nix ];

  options.cg.service.vikunja = {
    enable = lib.mkEnableOption "Vikunja task manager";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3456;
      description = "Port Vikunja listens on (localhost only)";
    };

    frontendHostname = lib.mkOption {
      type = lib.types.str;
      default = "tasks.${config.cg.fleet.domain}";
      defaultText = lib.literalExpression ''"tasks.''${config.cg.fleet.domain}"'';
      description = "Public hostname for Vikunja (used in links and CORS headers)";
    };
  };

  config = lib.mkIf cfg.enable {
    sops = {
      secrets = {
        # JWT secret — owned by root; injected via EnvironmentFile before the
        # service drops privileges. No DB password needed: peer auth on the
        # Unix socket matches by OS username ("vikunja") with no password.
        "vikunja/jwt-secret" = {
          mode = "0400";
          restartUnits = [ "vikunja.service" ];
        };
      };

      # Rendered EnvironmentFile interpolated at activation time.
      # Vikunja reads config from env using the VIKUNJA_<SECTION>_<KEY> convention.
      templates."vikunja-env" = {
        content = ''
          VIKUNJA_SERVICE_JWTSECRET=${config.sops.placeholder."vikunja/jwt-secret"}
        '';
        mode = "0400";
        restartUnits = [ "vikunja.service" ];
      };
    };

    # Create the vikunja PostgreSQL role and database declaratively.
    # ensureDBOwnership grants ownership so Vikunja can run its own migrations
    # on first start. Peer auth on the Unix socket requires no password.
    services.postgresql = {
      ensureUsers = [
        {
          name = "vikunja";
          ensureDBOwnership = true;
        }
      ];
      ensureDatabases = [ "vikunja" ];
    };

    services.vikunja = {
      enable = true;

      port = cfg.port;
      frontendScheme = "https";
      frontendHostname = cfg.frontendHostname;

      database = {
        type = "postgres";
        # Unix socket directory — peer auth, no password required.
        host = "/run/postgresql";
      };

      # JWT secret injected at runtime via env; never in the Nix store.
      environmentFiles = [
        config.sops.templates."vikunja-env".path
      ];

      settings = {
        service = {
          # Allow registration for first-run account creation.
          # Set to false and rebuild once your admin account exists.
          enableregistration = true;
        };

        # Mailer (disabled by default — add SMTP secrets to enable):
        # mailer = {
        #   enabled = true;
        #   host = "smtp.protonmail.ch";
        #   port = 587;
        #   username = "alerts@gyarmathy.co";
        #   fromemail = "vikunja@gyarmathy.co";
        # };
      };
    };
  };
}
