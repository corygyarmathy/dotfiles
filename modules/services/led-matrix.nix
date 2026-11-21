# HUB75 RGB LED panels driven from the GPIO header by hzeller's
# rpi-rgb-led-matrix (packages/rpi-rgb-led-matrix).
#
# The module owns what is the same whatever is shown: the panel geometry, the
# GPIO mapping, the kernel setup the library needs, and a confined unit to run
# it in. By default that unit runs matrix-display's frame sink, which takes
# frames from an unprivileged renderer over the unit's socket and holds the
# hardware for it (ADR 0011). `command` can be any other program linked
# against the library instead - the package's demos, for a panel test - and
# the `--led-*` flags are appended to whichever runs.
#
# SOCKET. systemd creates the socket and hands it to the sink, which never
# makes one itself, so who may send frames is decided here: root and the
# `socket.group`, through the socket's mode. A program other than the sink
# ignores the socket.
#
# PRIVILEGES. The library must start as root: it maps the SoC's GPIO, timer,
# PWM and (for hardware pulsing) clock registers through /dev/mem, which needs
# CAP_SYS_RAWIO, and it starts its refresh thread under SCHED_FIFO pinned to
# core 3, which needs CAP_SYS_NICE. Once the thread is running it drops to
# `led-matrix:led-matrix` (CAP_SETUID/CAP_SETGID), keeping the mappings. Its
# default drop target is `daemon:daemon`, which NixOS does not have - and it
# ignores that failure and carries on as root - so the user is always passed.
# The capability bounding set is exactly those four.
#
# KERNEL TUNABLES. At startup the library also raises the RT throttling limit
# and sets core 3's cpufreq governor, ignoring failure. The unit's
# ProtectKernelTunables makes both writes fail, so the module sets them at
# boot instead.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.led-matrix;

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

    sinkPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.matrix-display-sink.override { rpi-rgb-led-matrix = cfg.package; };
      defaultText = lib.literalExpression "pkgs.matrix-display-sink.override { rpi-rgb-led-matrix = cfg.package; }";
      description = ''
        The frame sink, linked against `package`, so a patched library
        reaches the panels through the sink as it does through the demos.
        `pkgs.matrix-display-sink` comes from matrix-display's overlay, in
        this flake's overlays.
      '';
    };

    command = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ (lib.getExe cfg.sinkPackage) ];
      defaultText = lib.literalExpression "[ (lib.getExe cfg.sinkPackage) ]";
      example = lib.literalExpression ''
        [
          (lib.getExe' cfg.package "demo")
          "-D0"
        ]
      '';
      description = ''
        Program and arguments to run. The `--led-*` flags are appended, so it
        must parse the library's options (the sink and every program in the
        library's package do). The default is the frame sink, which shows
        nothing until a renderer connects to `socket.path`; the example is
        the rotating-square demo, a panel test. Any other program ignores the
        socket, which still accepts connections, so while it runs a renderer
        connects and then waits with no error.
      '';
    };

    socket = {
      path = lib.mkOption {
        type = lib.types.path;
        default = "/run/led-matrix/frames.sock";
        readOnly = true;
        description = "Where a renderer connects to send the sink frames.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "led-matrix";
        readOnly = true;
        description = ''
          Group allowed to connect to `socket.path`. A renderer's unit joins
          it (for example through `SupplementaryGroups`).
        '';
      };
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
        library's fix for flicker.
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
      # IO_STRICT_DEVMEM refuses /dev/mem mappings of any region a driver has
      # claimed, even to root, and pinctrl and the clock driver have claimed
      # the GPIO block and the clock manager. Every mapping needs GPIO, so
      # every mapping needs this. The trade is ADR 0010.
      ++ [ "iomem=relaxed" ];

    # `relaxed` gives root little it lacks only while module loading is open.
    assertions = [
      {
        assertion = !config.security.lockKernelModules;
        message = "cg.service.led-matrix: iomem=relaxed on a host that locks kernel modules is the widest root-to-kernel path left there; revisit ADR 0010 before combining them";
      }
    ];

    # What the library writes at startup and the sandbox refuses (see the
    # header). 990000 is the library's value: the kernel's default 950000
    # leaves a 50ms gap a second that shows as flicker.
    boot.kernel.sysctl."kernel.sched_rt_runtime_us" = 990000;
    systemd.tmpfiles.rules = [
      "w /sys/devices/system/cpu/cpu3/cpufreq/scaling_governor - - - - performance"
    ];

    users.users.led-matrix = {
      isSystemUser = true;
      group = "led-matrix";
    };
    users.groups.led-matrix = { };

    # A connection socket-activates the service, which also starts at boot
    # (below) so the panels are driven blank rather than left floating.
    systemd.sockets.led-matrix = {
      description = "RGB LED matrix frame socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenSequentialPacket = cfg.socket.path;
        SocketUser = "root";
        SocketGroup = cfg.socket.group;
        SocketMode = "0660";
      };
    };

    systemd.services.led-matrix = {
      description = "RGB LED matrix display";
      wantedBy = [ "multi-user.target" ];
      requires = [ "led-matrix.socket" ];
      after = [ "led-matrix.socket" ];

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

        # Not PrivateDevices, which would hide /dev/mem; it is allowed by
        # name instead.
        DevicePolicy = "closed";
        DeviceAllow = [ "/dev/mem rw" ];

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
