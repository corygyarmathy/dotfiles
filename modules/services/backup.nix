# Backup Configuration
# Automated backups of critical service data
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.backup;

  backupScript = pkgs.writeShellScriptBin "backup-homelab" ''
    set -euo pipefail

    BACKUP_DEST="''${1:-/mnt/backup}"
    DATE=$(date +%Y-%m-%d_%H-%M)
    BACKUP_DIR="$BACKUP_DEST/homelab-$DATE"

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m' # No Color

    log() { echo -e "''${GREEN}[BACKUP]''${NC} $1"; }
    err() { echo -e "''${RED}[ERROR]''${NC} $1" >&2; }

    # Check if backup destination exists
    if [[ ! -d "$BACKUP_DEST" ]]; then
      err "Backup destination $BACKUP_DEST does not exist"
      err "Mount your backup drive first: sudo mount /dev/sdX1 /mnt/backup"
      exit 1
    fi

    log "Starting backup to $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"

    # Directories to backup (configs and irreplaceable data)
    # Media files are NOT backed up here - they're large and replaceable
    BACKUP_SOURCES=(
      "/srv/immich/upload"          # Photos - irreplaceable!
      "/srv/arr"                    # Arr stack configs
      "/var/lib/hass"               # Home Assistant config and database
      "/var/lib/jellyfin"           # Jellyfin config (not media)
      "/etc/nixos"                  # NixOS configuration
    )

    for src in "''${BACKUP_SOURCES[@]}"; do
      if [[ -d "$src" ]]; then
        log "Backing up $src..."
        dest_name=$(echo "$src" | tr '/' '_' | sed 's/^_//')
        ${pkgs.rsync}/bin/rsync -av --delete "$src/" "$BACKUP_DIR/$dest_name/"
      else
        err "Source directory $src does not exist, skipping"
      fi
    done

    # Create a manifest of what was backed up
    log "Creating backup manifest..."
    cat > "$BACKUP_DIR/MANIFEST.txt" << EOF
    Homelab Backup
    Date: $(date)
    Hostname: $(hostname)

    Backed up directories:
    $(for src in "''${BACKUP_SOURCES[@]}"; do echo "  - $src"; done)

    Disk usage:
    $(du -sh "$BACKUP_DIR"/* 2>/dev/null || echo "  Unable to calculate")
    EOF

    # Prune old backups (keep last 7)
    log "Pruning old backups (keeping last 7)..."
    cd "$BACKUP_DEST" && ls -dt homelab-* 2>/dev/null | tail -n +8 | xargs -r rm -rf

    log "Backup complete!"
    log "Location: $BACKUP_DIR"
    log "Size: $(du -sh "$BACKUP_DIR" | cut -f1)"
  '';
in
{
  options.cg.backup.enable = lib.mkEnableOption "Backup service";

  config = lib.mkIf cfg.enable {
    # Make backup script available system-wide
    environment.systemPackages = [ backupScript ];

    # Optional: Systemd timer for automated backups
    # Uncomment when you have a permanent backup location
    #
    # systemd.services.homelab-backup = {
    #   description = "Homelab Backup";
    #   serviceConfig = {
    #     Type = "oneshot";
    #     ExecStart = "${backupScript}/bin/backup-homelab /mnt/backup";
    #   };
    # };
    #
    # systemd.timers.homelab-backup = {
    #   description = "Weekly Homelab Backup";
    #   wantedBy = [ "timers.target" ];
    #   timerConfig = {
    #     OnCalendar = "Sun 02:00";  # Every Sunday at 2 AM
    #     Persistent = true;         # Run if missed (e.g., system was off)
    #   };
    # };

    # Mount point for backup drive (create the directory)
    systemd.tmpfiles.rules = [
      "d /mnt/backup 0755 root root -"
    ];
  };
}
