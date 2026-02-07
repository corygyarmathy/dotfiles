# Called by Jellyfin to post-process live TV recordings
# Enables automatically skipping through advertisements
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.comskip;

  # Post-processing script that Jellyfin will call
  # Jellyfin passes the recording path as the first argument
  postProcessScript = pkgs.writeShellScript "jellyfin-comskip" ''
    set -euo pipefail

    # Jellyfin passes the full path to the recording
    VIDEO_FILE="$1"

    if [ ! -f "$VIDEO_FILE" ]; then
      echo "ERROR: Video file does not exist: $VIDEO_FILE" >&2
      exit 1
    fi

    VIDEO_DIR=$(dirname "$VIDEO_FILE")
    VIDEO_BASE=$(basename "$VIDEO_FILE" .ts)
    EDL_FILE="$VIDEO_DIR/$VIDEO_BASE.edl"

    # Skip if EDL already exists (shouldn't happen, but be defensive)
    if [ -f "$EDL_FILE" ]; then
      echo "EDL already exists for $VIDEO_FILE, skipping"
      exit 0
    fi

    echo "Starting comskip processing for: $VIDEO_FILE"
    echo "Working directory: $VIDEO_DIR"

    # Change to the video directory so comskip outputs files there
    cd "$VIDEO_DIR"

    # Run comskip
    ${pkgs.comskip}/bin/comskip \
      --ini=${config.environment.etc."comskip/comskip.ini".source} \
      "$VIDEO_FILE"

    if [ -f "$EDL_FILE" ]; then
      echo "SUCCESS: Created EDL file at $EDL_FILE"
      exit 0
    else
      echo "WARNING: Comskip completed but no EDL file was created"
      exit 0
    fi
  '';

in
{
  options.cg.service.comskip = {
    enable = lib.mkEnableOption "Comskip commercial detection";

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Comskip configuration settings (comskip.ini format)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install comskip package
    environment.systemPackages = [ pkgs.comskip ];

    # Generate comskip.ini configuration
    environment.etc."comskip/comskip.ini".text = lib.generators.toINI { } (
      cfg.settings
      // {
        # Ensure these critical settings are always present
        output_edl = 1;
        output_videoredo = 0;
        output_projectx = 0;
        output_default = 0;
      }
    );

    # Create a systemd service that can be used for manual processing if needed
    systemd.services.comskip-manual = {
      description = "Manual Comskip processing";
      serviceConfig = {
        Type = "oneshot";
        # Use the jellyfin user since it owns the recordings
        User = "jellyfin";
        Group = "jellyfin";
      };
      # This service is not started automatically - it's just for manual use
      script = ''
        if [ -z "''${VIDEO_FILE:-}" ]; then
          echo "Usage: systemctl start comskip-manual VIDEO_FILE=/path/to/recording.ts"
          exit 1
        fi
        ${postProcessScript} "$VIDEO_FILE"
      '';
    };

    # Make the post-processing script available at a well-known location
    # Jellyfin needs to reference this in its DVR settings
    environment.etc."jellyfin/comskip-post-process".source = postProcessScript;
  };
}
