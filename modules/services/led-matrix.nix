# HUB75 RGB LED panels driven from the GPIO header by hzeller's
# rpi-rgb-led-matrix (packages/rpi-rgb-led-matrix).
#
# The module owns what is the same whatever is shown: the panel geometry, the
# GPIO mapping, the kernel setup the library needs, and a confined unit to run
# it in. What is shown is the host's choice - `command` is any program linked
# against the library (the package's own demos and utilities, or something
# else), and the `--led-*` flags are appended to it.
#
# PRIVILEGES. The library must start as root: it maps the SoC's timer, PWM and
# (for hardware pulsing) clock registers through /dev/mem, which needs
# CAP_SYS_RAWIO, and it starts its refresh thread under SCHED_FIFO pinned to
# core 3, which needs CAP_SYS_NICE. Once the thread is running it drops to
# `led-matrix:led-matrix` (CAP_SETUID/CAP_SETGID), keeping the mappings. Its
# default drop target is `daemon:daemon`, which NixOS does not have - and it
# ignores that failure and carries on as root - so the user is always passed.
# The capability bounding set is exactly those four.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.led-matrix;

  hardwarePulsing = cfg.gpioMapping == "adafruit-hat-pwm";

  matrixFlags = [
    "--led-gpio-mapping=${cfg.gpioMapping}"
    "--led-rows=${toString cfg.rows}"
    "--led-cols=${toString cfg.cols}"
    "--led-chain=${toString cfg.chain}"
    "--led-slowdown-gpio=${toString cfg.slowdownGpio}"
    "--led-drop-priv-user=led-matrix"
    "--led-drop-priv-group=led-matrix"
  ]
  ++ cfg.extraFlags;
in
{
  options.cg.service.led-matrix = {
    enable = lib.mkEnableOption "an RGB LED matrix display driven from the GPIO header";

    package = lib.mkPackageOption pkgs "rpi-rgb-led-matrix" { };

    command = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [
        (lib.getExe' cfg.package "demo")
        "-D0"
      ];
      defaultText = lib.literalExpression ''[ (lib.getExe' cfg.package "demo") "-D0" ]'';
      example = lib.literalExpression ''
        [
          (lib.getExe' cfg.package "text-scroller")
          "-f" "''${cfg.package}/share/rpi-rgb-led-matrix/fonts/10x20.bdf"
          "Hello"
        ]
      '';
      description = ''
        Program and arguments to run. The `--led-*` flags are appended, so it
        must parse the library's options (every program in the package does).
        The default is the rotating-square demo - a panel test, not content.
      '';
    };

    gpioMapping = lib.mkOption {
      type = lib.types.enum [
        "regular"
        "adafruit-hat"
        "adafruit-hat-pwm"
      ];
      default = "regular";
      description = ''
        How the panels are wired to the header. `adafruit-hat-pwm` is the
        Adafruit HAT/Bonnet with GPIO4 bridged to GPIO18, which lets the PWM
        block time the output-enable pulses instead of software - the
        library's fix for flicker. It needs the clock manager's registers,
        which the kernel only lets /dev/mem map with `iomem=relaxed`, so this
        mapping adds that kernel parameter.
      '';
    };

    rows = lib.mkOption {
      type = lib.types.ints.positive;
      default = 32;
      description = "Rows of one panel.";
    };

    cols = lib.mkOption {
      type = lib.types.ints.positive;
      default = 32;
      description = "Columns of one panel.";
    };

    chain = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Panels daisy-chained on the one output, left to right.";
    };

    slowdownGpio = lib.mkOption {
      type = lib.types.ints.between 0 4;
      default = 1;
      description = ''
        How much to slow GPIO writes down for the panels to keep up. A Pi 4
        is fast enough that most panels need 2 or more.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--led-pwm-bits=8"
        "--led-brightness=60"
      ];
      description = "Further `--led-*` flags, for tuning refresh rate and colour depth.";
    };

    isolateCore = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Keep the scheduler off core 3 (`isolcpus=3`), which the library pins
        its refresh thread to. Anything else running there shows as flicker.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelParams =
      lib.optional cfg.isolateCore "isolcpus=3"
      # The kernel's IO_STRICT_DEVMEM refuses /dev/mem mappings of any region
      # a driver has claimed, even to root, and the clock driver has claimed
      # the clock manager. `relaxed` lifts that for root only; it gives root
      # little it lacks on a host that does not lock module loading, since a
      # module can map anything. GPIO itself comes through /dev/gpiomem either
      # way (packages/rpi-rgb-led-matrix's patch), so the plain mappings need
      # none of this. The trade is ADR 0010.
      ++ lib.optional hardwarePulsing "iomem=relaxed";

    users.users.led-matrix = {
      isSystemUser = true;
      group = "led-matrix";
    };
    users.groups.led-matrix = { };

    systemd.services.led-matrix = {
      description = "RGB LED matrix display";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = lib.escapeShellArgs (cfg.command ++ matrixFlags);
        Restart = "on-failure";
        RestartSec = "5s";

        # Starts as root for the reasons in the header, then drops itself.
        CapabilityBoundingSet = [
          "CAP_SYS_RAWIO"
          "CAP_SYS_NICE"
          "CAP_SETUID"
          "CAP_SETGID"
        ];
        NoNewPrivileges = true;

        # Not PrivateDevices, which would hide /dev/mem; the two device nodes
        # are allowed by name instead.
        DevicePolicy = "closed";
        DeviceAllow = [
          "/dev/mem rw"
          "/dev/gpiomem rw"
        ];

        # Displays need no network; a host whose command fetches content
        # overrides these.
        PrivateNetwork = lib.mkDefault true;
        RestrictAddressFamilies = lib.mkDefault [ "AF_UNIX" ];
        IPAddressDeny = lib.mkDefault "any";

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        # RestrictRealtime stays off: the refresh thread runs SCHED_FIFO.
      };
    };
  };
}
