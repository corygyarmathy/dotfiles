# Example: Updated service toggles for hosts/homelab01/default.nix
# Replace your current cg.service block with this structure
#
# The old arr-stack.nix is now split into individual modules under media-stack/
# Delete the old files after migration:
#   - modules/services/arr-stack.nix
#   - modules/services/jellyfin.nix (moved to media-stack/)
#   - modules/services/recyclarr.nix (moved to media-stack/)
#   - modules/services/cleanuparr.nix (moved to media-stack/)
#   - modules/services/huntarr.nix (moved to media-stack/)
#   - modules/services/wizarr.nix (moved to media-stack/)
#   - modules/services/cross-seed.nix (moved to media-stack/)

cg.service = {
  # Non-media services (unchanged)
  backup.enable = false;
  immich.enable = false;
  home-assistant.enable = false;
  monitoring.enable = true;
  reverse-proxy.enable = false;

  # ============================================================================
  # Media Stack
  # ============================================================================

  # Shared infrastructure (REQUIRED for all media services)
  media-stack = {
    enable = true;
    # These are the defaults, shown for documentation:
    # dataPath = "/srv/media";
    # configPath = "/srv/arr";
    # user = "coryg";
    # group = "media";

    # NFS configuration (disabled by default)
    # Enable this when homelab02 NAS is ready:
    # storage = {
    #   type = "nfs";
    #   nfsServer = "homelab02.local";
    #   nfsExportPath = "/export/media";
    # };
  };

  # Core *arr services
  sonarr.enable = true;
  radarr.enable = true;
  prowlarr.enable = true;
  bazarr.enable = true;

  # Download client
  qbittorrent = {
    enable = true;
    vpn = {
      enable = true;
      serverCountry = "Australia";
    };
  };

  # Media server
  jellyfin.enable = true;

  # Supporting services
  jellyseerr.enable = true;
  flaresolverr.enable = true;

  # Automation helpers
  recyclarr.enable = true;
  huntarr.enable = true;
  cleanuparr.enable = true;
  wizarr.enable = true;

  # Cross-seed (enable when ready to build ratio)
  cross-seed.enable = false;
};
