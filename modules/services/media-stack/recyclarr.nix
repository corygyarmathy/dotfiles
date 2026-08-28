# Recyclarr - TRaSH Guides Sync
# Automatically syncs quality profiles and custom formats from TRaSH Guides
# to Sonarr and Radarr
#
# Runs as a native systemd oneshot + timer via the nixpkgs `services.recyclarr`
# module (no container). API keys are injected from sops via systemd
# LoadCredential, so they never appear in the Nix store.
#
# SETUP AFTER DEPLOYMENT:
# 1. No web UI - runs on a schedule (daily by default)
# 2. Add API keys to sops secrets:
#    - media-stack/sonarr/api
#    - media-stack/radarr/api
# 3. Config is managed via Nix (the `settings` option)
# 4. Check logs: journalctl -u recyclarr
# 5. Run on demand: systemctl start recyclarr
#
# The default config includes:
# - Sonarr: WEB-1080p (Alternative), WEB-2160p (Alternative), [Anime] Remux-1080p
# - Radarr: HD Bluray + WEB, UHD Bluray + WEB, [Anime] Remux-1080p
#
# The Sonarr WEB profiles are deliberately the "(Alternative)" variants. TRaSH
# Guides presents the plain WEB-1080p / WEB-2160p as the standard choice and
# treats these as an opt-in, but the Alternative variants add 720p / HDTV /
# Bluray fallbacks so that a show whose preferred quality was never released
# still gets grabbed instead of being skipped. That fallback behaviour is wanted
# here. Do not "simplify" these back to the plain profiles.
# https://trash-guides.info/Sonarr/sonarr-setup-quality-profiles/
#
# CUSTOMIZATION:
# Override `settings` to customize profiles and custom format groups.
# See: https://recyclarr.dev/reference/configuration/
#
# RECYCLARR v8 NOTE:
# v8 removed the shared `include:` templates that older configs relied on, and
# replaced the `custom_formats` list with guide-backed `custom_format_groups`.
# Profiles and CF groups are therefore referenced directly by `trash_id` below.
# The IDs come from the upstream templates in recyclarr/config-templates; the
# actual scores and format definitions are still pulled from TRaSH Guides on
# every sync, so this stays current without manual edits.
#
# MIGRATION NOTES (homelab02 NAS):
# Recyclarr stays on homelab01 alongside Sonarr/Radarr.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.recyclarr;
  stack = config.cg.service.media-stack;

  # Marks a profile as "reset scores that the guide doesn't define", matching
  # the upstream templates.
  profile = trash_id: {
    inherit trash_id;
    reset_unmatched_scores.enabled = true;
  };

  # Default TRaSH Guides configuration.
  #
  # Sonarr and Radarr each get a single instance. Only one `quality_definition`
  # can apply per instance, so the anime profiles ride along with the series /
  # movie definitions - the same trade-off the previous config made by including
  # the series and movie quality definitions exactly once.
  defaultSettings = {
    sonarr.shows = {
      base_url = "https://sonarr.${config.cg.fleet.domain}";
      api_key._secret = config.sops.secrets."media-stack/sonarr/api".path;
      delete_old_custom_formats = true;

      media_naming = {
        series = "jellyfin-tvdb";
        season = "default";
        episodes = {
          rename = true;
          standard = "default";
          daily = "default";
          anime = "default";
        };
      };

      quality_definition.type = "series";

      quality_profiles = [
        (profile "9d142234e45d6143785ac55f5a9e8dc9") # WEB-1080p (Alternative)
        (profile "dfa5eaae7894077ad6449169b6eb03e0") # WEB-2160p (Alternative)
        (profile "20e0fc959f1f1704bed501f23bdae76f") # [Anime] Remux-1080p
      ];

      custom_format_groups.add = [
        { trash_id = "158188097a58d7687dee647e04af0da3"; } # [Optional] Golden Rule HD
        { trash_id = "e3f37512790f00d0e89e54fe5e790d1c"; } # [Optional] Golden Rule UHD
        { trash_id = "74aff4168620ed49dcc67e92b2c2a5b4"; } # [Optional] Language Profiles
        { trash_id = "85fae4a2294965b75710ef2989c850eb"; } # [Streaming Services] HD/UHD boost
        { trash_id = "59c3af66780d08332fdc64e68297098f"; } # [Unwanted] Unwanted Formats
      ];
    };

    radarr.movies = {
      base_url = "https://radarr.${config.cg.fleet.domain}";
      api_key._secret = config.sops.secrets."media-stack/radarr/api".path;
      delete_old_custom_formats = true;

      media_naming = {
        folder = "jellyfin-tmdb";
        movie = {
          rename = true;
          standard = "jellyfin-tmdb";
        };
      };

      quality_definition.type = "movie";

      quality_profiles = [
        (profile "d1d67249d3890e49bc12e275d989a7e9") # HD Bluray + WEB
        (profile "64fb5f9858489bdac2af690e27c8f42f") # UHD Bluray + WEB
        (profile "722b624f9af1e492284c4bc842153a38") # [Anime] Remux-1080p
      ];

      custom_format_groups.add = [
        { trash_id = "f8bf8eab4617f12dfdbd16303d8da245"; } # [Optional] Golden Rule HD
        { trash_id = "ff204bbcecdd487d1cefcefdbf0c278d"; } # [Optional] Golden Rule UHD
        { trash_id = "a3ac6af01d78e4f21fcb75f601ac96df"; } # [Unwanted] Unwanted Formats
      ];
    };
  };
in
{
  # Reads config.cg.fleet, so it declares it - see modules/nixos/fleet.nix.
  imports = [ ../../nixos/fleet.nix ];

  options.cg.service.recyclarr = {
    enable = lib.mkEnableOption "Recyclarr TRaSH Guide sync";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "When to sync, in systemd OnCalendar format";
    };

    settings = lib.mkOption {
      type = (pkgs.formats.yaml { }).type;
      default = defaultSettings;
      defaultText = lib.literalMD "TRaSH Guides profiles for Sonarr and Radarr";
      description = ''
        Recyclarr configuration as a Nix attribute set.

        An `api_key` may be given as `{ _secret = "/path/to/file"; }` to load it
        from disk at runtime instead of embedding it in the Nix store.

        See <https://recyclarr.dev/reference/configuration/>.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "recyclarr requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Sops secrets for API keys
    sops.secrets."media-stack/sonarr/api" = { };
    sops.secrets."media-stack/radarr/api" = { };

    services.recyclarr = {
      enable = true;
      schedule = cfg.schedule;
      configuration = cfg.settings;
    };

    systemd.services.recyclarr = {
      # sops decrypts into /run/secrets during activation; make sure a
      # boot-time trigger of the timer can't beat it.
      after = [ "sops-install-secrets.service" ];

      serviceConfig = {
        # preStart expands the API keys into /var/lib/recyclarr/config.yml.
        # jq inherits the service umask, and the default leaves that file
        # world-readable with the keys in plaintext.
        UMask = "0077";
        StateDirectoryMode = "0700";
      };
    };
  };
}
