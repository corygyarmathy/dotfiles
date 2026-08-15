# Grimmory - Unified Reading Server (ebooks, comics, audiobooks)
# Serves EPUB/MOBI/AZW3/FB2, PDF, CBZ/CBR/CB7 and M4B/MP3 from one library,
# with a browser reader, Kobo sync, KOReader progress sync and OPDS.
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://homelab02:6060 (or https://grimmory.gyarmathy.co)
# 2. Create an admin account on first launch
# 3. Add libraries pointing at the in-container paths:
#    - /books/books       (ebooks)
#    - /books/comics      (comics)
#    - /books/manga       (manga)
#    - /books/audiobooks  (audiobooks)
# 4. Point acquisition tooling at /srv/media/bookdrop for automatic import
#
# WHY THIS RUNS ON homelab02, NOT homelab01:
# Grimmory disables all UI-initiated file operations (delete, move, rename) when
# DISK_TYPE=NETWORK, and its BookDrop watcher relies on filesystem notifications
# that do not fire reliably over NFS. homelab01 mounts /srv/media over NFS from
# homelab02 (hosts/homelab01/default.nix, storage.type = "nfs"), so running it
# there would cost both. On homelab02 the ZFS pool is local, so DISK_TYPE stays
# LOCAL and inotify works. Caddy on homelab01 proxies across for external access.
#
# SCHEMA MIGRATIONS AND :latest:
# Grimmory runs schema migrations against MariaDB on startup, so a new image can
# change the database on first boot. That is not a reason to pin the tag: the
# migration is one-way whenever it happens, so recovery means restoring a dump
# either way, and a pinned tag only chooses the moment -- at the cost of never
# actually updating. wallabag.nix runs Doctrine migrations on :latest for the
# same reason. What does help is a *fresh* restore point, so grimmory-db-backup
# runs before every start of the app, not just nightly. See BACKUPS below.
#
# WHY MARIADB IS A SIDECAR RATHER THAN A HOST SERVICE:
# wallabag.nix shares homelab01's PostgreSQL because that server already exists
# and serves several apps. homelab02 has no MySQL at all, so a host MariaDB would
# exist solely for this one app -- no consolidation to gain, and it would need the
# podman0 bridge plumbing wallabag needs. Upstream ships and tests this exact
# image pairing, and keeping the pair together makes backup/restore one unit.
#
# BACKUPS:
# Restic snapshots of a live MariaDB datadir are torn and may not restore. This
# module therefore dumps the database to ${configPath}/grimmory/db-dump ahead of
# the nightly backup window, and homelab02 excludes the raw datadir from restic.
# The same dump also runs immediately before the app starts, so an image that
# migrates the schema is always preceded by a restore point minutes old rather
# than up to a day old.
#
# COEXISTENCE WITH KAVITA AND AUDIOBOOKSHELF:
# All three are read-only consumers of the same directories, so they can run in
# parallel indefinitely. Nothing here retires them.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.grimmory;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.grimmory = {
    enable = lib.mkEnableOption "Grimmory reading server";

    port = lib.mkOption {
      type = lib.types.port;
      default = 6060;
      description = "Port for the Grimmory web UI";
    };

    mariadbTag = lib.mkOption {
      type = lib.types.str;
      default = "11.4.8";
      description = ''
        MariaDB image tag. Pinned on purpose -- see the comment on the container
        below. Bump one major at a time, and read MariaDB's upgrade notes first.
      '';
    };

    heapSize = lib.mkOption {
      type = lib.types.str;
      default = "1g";
      description = ''
        JVM maximum heap. The image defaults to roughly 512 MB, which is tight
        once a large library's metadata is cached. homelab02 has 16 GB total and
        already runs qBittorrent, Gluetun and cross-seed, so this is not free.
      '';
    };

    diskType = lib.mkOption {
      type = lib.types.enum [
        "LOCAL"
        "NETWORK"
      ];
      default = "LOCAL";
      description = ''
        Storage mode. NETWORK disables UI-initiated file operations (delete,
        move, rename) to avoid destructive changes on shared mounts; reading,
        metadata and sync are unaffected. Must be NETWORK if the library is on
        an NFS/SMB mount rather than local disk.
      '';
    };

    dbBackupTime = lib.mkOption {
      type = lib.types.str;
      default = "02:00";
      description = ''
        When to dump the database. Must land before the restic window
        (cg.service.backup.repositories.*.schedule, 02:30) so the nightly
        snapshot picks up a consistent dump.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = stack.enable;
        message = "grimmory requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
      {
        # Catches the homelab01 footgun described in the header: pointing
        # Grimmory at an NFS-mounted library while claiming it is local.
        assertion = stack.storage.type != "nfs" || cfg.diskType == "NETWORK";
        message = ''
          grimmory: media-stack storage is NFS, so cg.service.grimmory.diskType
          must be "NETWORK". Grimmory's file operations and BookDrop watcher are
          not safe over a network mount.
        '';
      }
    ];

    sops.secrets = {
      "media-stack/grimmory/db-password" = { };
      "media-stack/grimmory/db-root-password" = { };
    };

    # Rendered at activation so the passwords never enter the Nix store, and
    # passed to Podman via --env-file rather than into the container filesystem.
    sops.templates = {
      "grimmory-db-env" = {
        content = ''
          MYSQL_ROOT_PASSWORD=${config.sops.placeholder."media-stack/grimmory/db-root-password"}
          MYSQL_DATABASE=grimmory
          MYSQL_USER=grimmory
          MYSQL_PASSWORD=${config.sops.placeholder."media-stack/grimmory/db-password"}
        '';
        mode = "0400";
        restartUnits = [ "podman-grimmory-mariadb.service" ];
      };

      "grimmory-env" = {
        content = ''
          DATABASE_PASSWORD=${config.sops.placeholder."media-stack/grimmory/db-password"}
        '';
        mode = "0400";
        restartUnits = [ "podman-grimmory.service" ];
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/grimmory 0775 ${stack.user} ${stack.group} -"
      "d ${stack.configPath}/grimmory/data 0775 ${stack.user} ${stack.group} -"
      "d ${stack.configPath}/grimmory/mariadb 0775 ${stack.user} ${stack.group} -"
      # Dumps contain the whole database; keep them off the group-readable path.
      "d ${stack.configPath}/grimmory/db-dump 0700 root root -"
    ];

    virtualisation.oci-containers.containers = {
      grimmory-mariadb = {
        # The database engine stays pinned even though the app tracks :latest.
        # This is a different risk: MariaDB rewrites its datadir on a major
        # upgrade and will not read it again on the older version, and majors
        # must be crossed one at a time with mariadb-upgrade. A :latest that
        # jumps 11.4 to 12.x is unrecoverable by restarting the old image,
        # whereas an app migration is just a restore. Upstream pins it too.
        image = "lscr.io/linuxserver/mariadb:${cfg.mariadbTag}";
        environment = {
          PUID = toString config.users.users.${stack.user}.uid;
          PGID = toString config.users.groups.${stack.group}.gid;
          TZ = config.time.timeZone;
        };
        environmentFiles = [ config.sops.templates."grimmory-db-env".path ];
        volumes = [
          "${stack.configPath}/grimmory/mariadb:/config"
        ];
        # No ports: reachable only as `grimmory-mariadb` on arr-network.
        extraOptions = [
          "--network=arr-network"
        ];
      };

      grimmory = {
        image = "ghcr.io/grimmory-tools/grimmory:latest";
        environment = {
          USER_ID = toString config.users.users.${stack.user}.uid;
          GROUP_ID = toString config.users.groups.${stack.group}.gid;
          TZ = config.time.timeZone;
          DATABASE_URL = "jdbc:mariadb://grimmory-mariadb:3306/grimmory";
          DATABASE_USERNAME = "grimmory";
          DISK_TYPE = cfg.diskType;
          SWAGGER_ENABLED = "false";
          JDK_JAVA_OPTIONS = "-Xmx${cfg.heapSize}";
        };
        environmentFiles = [ config.sops.templates."grimmory-env".path ];
        # Mounted per-library rather than handing over all of dataPath, so a
        # reading server has no path to the movie and TV trees.
        volumes = [
          "${stack.configPath}/grimmory/data:/app/data"
          "${stack.dataPath}/books:/books/books"
          "${stack.dataPath}/comics:/books/comics"
          "${stack.dataPath}/manga:/books/manga"
          "${stack.dataPath}/doujin:/books/doujin"
          "${stack.dataPath}/lightnovels:/books/lightnovels"
          "${stack.dataPath}/audiobooks:/books/audiobooks"
          "${stack.dataPath}/bookdrop:/bookdrop"
        ];
        ports = [ "${toString cfg.port}:6060" ];
        dependsOn = [ "grimmory-mariadb" ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
        ];
      };
    };

    systemd.services = {
      podman-grimmory-mariadb = {
        after = [ "podman-network-arr.service" ];
        requires = [ "podman-network-arr.service" ];
      };

      podman-grimmory = {
        # nas-directory-setup builds the media tree but is only ordered against
        # zfs.target, so without this the container can be started before
        # /srv/media/bookdrop exists and Podman fails the mount outright
        # ("statfs ...: no such file or directory") rather than waiting.
        after = [
          "podman-network-arr.service"
        ]
        ++ lib.optional config.cg.service.nas-storage.enable "nas-directory-setup.service";
        requires = [
          "podman-network-arr.service"
        ]
        ++ lib.optional config.cg.service.nas-storage.enable "nas-directory-setup.service";
      };

      # Consistent dump for restic to pick up -- see BACKUPS above.
      #
      # Ordered before the app as well as run nightly, so the dump also acts as
      # the restore point for whatever schema migration the next :latest image
      # brings. Wanted rather than required by podman-grimmory: a dump that
      # cannot run is worth an alert, never a reason to keep the app down.
      grimmory-db-backup = {
        description = "Dump the Grimmory MariaDB database for backup";
        after = [ "podman-grimmory-mariadb.service" ];
        requires = [ "podman-grimmory-mariadb.service" ];
        before = [ "podman-grimmory.service" ];
        wantedBy = [ "podman-grimmory.service" ];

        path = [
          pkgs.podman
          pkgs.gzip
        ];

        serviceConfig = {
          Type = "oneshot";
          # Deliberately no RemainAfterExit: this must run again on every
          # restart of the app, not once per boot.
          TimeoutStartSec = "5min";
          LoadCredential = [
            "db-password:${config.sops.secrets."media-stack/grimmory/db-password".path}"
          ];
        };

        script = ''
          set -euo pipefail

          DEST=${stack.configPath}/grimmory/db-dump
          DB_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/db-password")

          # Podman reports the container started well before MariaDB accepts
          # connections, and on the pre-start path it may have only just come
          # up. Nothing to dump is also the normal state on a first ever boot.
          for attempt in $(seq 60); do
            if podman exec --env "MYSQL_PWD=$DB_PASSWORD" grimmory-mariadb \
                 mariadb-admin --user=grimmory ping >/dev/null 2>&1; then
              break
            fi
            if [ "$attempt" = 60 ]; then
              echo "MariaDB did not accept connections within 120s; no dump taken"
              exit 1
            fi
            sleep 2
          done

          # A crash-looping app would otherwise re-dump on every restart. Any
          # dump taken in the last five minutes still predates the migration
          # being guarded against, so it is just as good a restore point.
          if [ -f "$DEST/grimmory.sql.gz" ] \
             && [ -z "$(find "$DEST/grimmory.sql.gz" -mmin +5)" ]; then
            echo "Dump from the last 5 minutes already exists, skipping"
            exit 0
          fi

          # Write to a temporary file and rename, so restic can never snapshot a
          # dump that is still being written.
          podman exec -i \
            --env "MYSQL_PWD=$DB_PASSWORD" \
            grimmory-mariadb \
            mariadb-dump --user=grimmory --single-transaction --quick grimmory \
            | gzip > "$DEST/grimmory.sql.gz.tmp"

          mv "$DEST/grimmory.sql.gz.tmp" "$DEST/grimmory.sql.gz"
          echo "Dumped Grimmory database to $DEST/grimmory.sql.gz"
        '';
      };
    };

    systemd.timers.grimmory-db-backup = {
      description = "Timer for the Grimmory database dump";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dbBackupTime;
        Persistent = true;
        Unit = "grimmory-db-backup.service";
      };
    };

    # Caddy and cloudflared on homelab01 proxy to this port across the LAN.
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
