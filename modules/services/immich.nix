# Immich - Self-hosted photo management
# Using docker-compose due to Immich's tightly coupled multi-container architecture
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.immich;
  immichRoot = "/srv/immich";
  # Pin to a specific version for stability
  # Check https://github.com/immich-app/immich/releases for latest
  immichVersion = "v1.120.0";
in
{
  options.cg.service.immich.enable = lib.mkEnableOption "Immich service";

  config = lib.mkIf cfg.enable {
    # Immich requires docker-compose due to its multi-container architecture
    # (server, microservices, machine-learning, redis, postgres)
    environment.systemPackages = [ pkgs.docker-compose ];

    # Create Immich directories
    systemd.tmpfiles.rules = [
      "d ${immichRoot} 0755 root root -"
      "d ${immichRoot}/upload 0755 root root -"
      "d ${immichRoot}/postgres 0755 root root -"
    ];

    # Create the docker-compose.yml for Immich
    # This follows the official Immich docker-compose structure
    environment.etc."immich/docker-compose.yml".text = ''
      name: immich

      services:
        immich-server:
          container_name: immich_server
          image: ghcr.io/immich-app/immich-server:${immichVersion}
          volumes:
            - ${immichRoot}/upload:/usr/src/app/upload
            - /etc/localtime:/etc/localtime:ro
          env_file:
            - ${config.sops.templates."immich-env".path}
          ports:
            - 2283:2283
          depends_on:
            - redis
            - database
          restart: unless-stopped
          healthcheck:
            disable: false

        immich-machine-learning:
          container_name: immich_machine_learning
          image: ghcr.io/immich-app/immich-machine-learning:${immichVersion}
          volumes:
            - ${immichRoot}/model-cache:/cache
          env_file:
            - ${config.sops.templates."immich-env".path}
          restart: unless-stopped
          healthcheck:
            disable: false

        redis:
          container_name: immich_redis
          image: docker.io/redis:6.2-alpine
          healthcheck:
            test: redis-cli ping || exit 1
          restart: unless-stopped

        database:
          container_name: immich_postgres
          image: docker.io/tensorchord/pgvecto-rs:pg14-v0.2.0
          environment:
            POSTGRES_PASSWORD: ''${DB_PASSWORD}
            POSTGRES_USER: ''${DB_USERNAME}
            POSTGRES_DB: ''${DB_DATABASE_NAME}
            POSTGRES_INITDB_ARGS: '--data-checksums'
          volumes:
            - ${immichRoot}/postgres:/var/lib/postgresql/data
          healthcheck:
            test: pg_isready --dbname=''${DB_DATABASE_NAME} --username=''${DB_USERNAME} || exit 1; Chksum="$$(psql --dbname=''${DB_DATABASE_NAME} --username=''${DB_USERNAME} --tuples-only --no-align --command='SELECT COALESCE(SUM(googlechecksum(googlechecksum(tablename::bytea, key::bytea), value::bytea)), 0) FROM pg_catalog.pg_settings')"; echo "googlechecksum: $$Chksum"
            interval: 5m
            start_interval: 30s
            start_period: 5m
          command:
            [
              'postgres',
              '-c',
              'shared_preload_libraries=vectors.so',
              '-c',
              'search_path="$$user", public, vectors',
              '-c',
              'logging_collector=on',
              '-c',
              'max_wal_size=2GB',
              '-c',
              'shared_buffers=512MB',
              '-c',
              'wal_compression=on',
            ]
          restart: unless-stopped
    '';

    # The .env file Immich's containers read. The database password comes from
    # sops rather than a literal: a default password in a module is the kind of
    # thing that survives being enabled, so there is deliberately none. The
    # secret name is declared here, and checks/secrets.nix fails the gate if it
    # is missing from the file the host reads - which is what turns "enable
    # immich" into a request for a real password rather than a working install.
    sops.secrets."immich/db-password" = {
      mode = "0400";
      restartUnits = [ "immich.service" ];
    };

    sops.templates."immich-env" = {
      content = ''
        # Database
        DB_PASSWORD=${config.sops.placeholder."immich/db-password"}
        DB_USERNAME=postgres
        DB_DATABASE_NAME=immich

        # Immich settings
        UPLOAD_LOCATION=${immichRoot}/upload
        IMMICH_VERSION=${immichVersion}

        # Optional: Hardware acceleration
        # Uncomment if you want to use Intel Quick Sync for video transcoding
        # IMMICH_FFMPEG_HW_ACCEL=vaapi
      '';
      mode = "0400";
    };

    # Systemd service to manage Immich via docker-compose
    systemd.services.immich = {
      description = "Immich Photo Management";
      after = [
        "network.target"
        "podman.service"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.docker-compose ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = "/etc/immich";
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose up -d";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose down";
        ExecReload = "${pkgs.docker-compose}/bin/docker-compose pull && ${pkgs.docker-compose}/bin/docker-compose up -d";
      };
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ 2283 ];
  };
}
