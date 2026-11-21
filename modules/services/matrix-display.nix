# matrix-display's renderer: computes every frame for the LED panels and sends
# them to the frame sink that cg.service.led-matrix runs (ADR 0011).
#
# It holds nothing privileged. The sink owns the hardware, so this unit needs
# only the sink's socket (through the socket's group) and, for its data
# sources, the network. Everything else is taken away.
#
# LOCATION. The sun's position needs a latitude and longitude, and the repo is
# public while the location is not. It lives in sops and reaches the renderer
# through LoadCredential: PID 1 reads the root-only secret and hands the
# service a copy only it can read, so the value is never in the Nix store,
# the unit file or the command line. The renderer never logs it.
#
# SOURCES. Presence, alerts and calendar (matrix-display#8, #9, #10) do not
# exist upstream yet, so neither do their options or the Home Assistant
# token. The unit already has the network they will need.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.matrix-display;
  sink = config.cg.service.led-matrix;

  locationSecret = "matrix-display/location";
in
{
  options.cg.service.matrix-display = {
    enable = lib.mkEnableOption "matrix-display's renderer, which drives the LED matrix's frame sink";

    package = lib.mkPackageOption pkgs "matrix-display" { };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--fps=60"
        "--east=right"
        "--ceiling=0.3"
      ];
      description = ''
        Further arguments to `matrix-display serve`: the frame rate and the
        art's tuning. `matrix-display serve -h` lists them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = sink.enable;
        message = "cg.service.matrix-display sends its frames to cg.service.led-matrix's sink, which is not enabled";
      }
    ];

    # On the PATH for running it by hand: `test-pattern`, or `serve --from`
    # to see another time of day. Stop the service first, since the sink
    # serves one client, and run it with sudo, for the socket and the
    # location secret (which LoadCredential's copy is not, once the service
    # stops).
    environment.systemPackages = [ cfg.package ];

    # Root-only; only PID 1 reads it, for LoadCredential.
    sops.secrets.${locationSecret}.restartUnits = [ "matrix-display.service" ];

    users.users.matrix-display = {
      isSystemUser = true;
      group = "matrix-display";
    };
    users.groups.matrix-display = { };

    systemd.services.matrix-display = {
      description = "matrix-display renderer";
      # Wanted by the socket too: the binding stops the renderer when the
      # socket stops, and nothing else would start it again with the socket.
      wantedBy = [
        "multi-user.target"
        "led-matrix.socket"
      ];
      # Connecting starts the sink if it is not running. Bound to the socket
      # rather than the sink: the sink restarting is something the renderer
      # rides out by redialling, the socket going away is not. No
      # network-online.target: its sources back off and retry on their own,
      # and the art needs no network, so the panels need not wait for Wi-Fi.
      bindsTo = [ "led-matrix.socket" ];
      after = [ "led-matrix.socket" ];

      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "serve"
            "--socket=${sink.socket.path}"
            "--location=%d/location"
          ]
          ++ cfg.extraArgs
        );
        LoadCredential = [ "location:${config.sops.secrets.${locationSecret}.path}" ];
        Restart = "on-failure";
        RestartSec = "5s";

        User = "matrix-display";
        Group = "matrix-display";
        SupplementaryGroups = [ sink.socket.group ];

        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;

        # Unix for the sink; IP for the sources.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];

        PrivateDevices = true;
        DevicePolicy = "closed";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        UMask = "0077";
      };
    };
  };
}
