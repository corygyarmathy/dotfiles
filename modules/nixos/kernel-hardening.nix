# modules/nixos/kernel-hardening.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.kernel-hardening;
in
{
  options.cg.kernel-hardening = {
    enable = lib.mkEnableOption "Kernel security hardening";

    # TODO: make server option (replace 'paranoid'?)
    level = lib.mkOption {
      type = lib.types.enum [
        "desktop"
        "paranoid"
      ];
      default = "desktop";
      description = "Hardening level - desktop is balanced, paranoid may break things";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl = {
      # Disable magic SysRq key (except for sync and reboot)
      "kernel.sysrq" = 176;

      # Restrict dmesg access
      "kernel.dmesg_restrict" = 1;

      # Restrict kernel pointer exposure
      "kernel.kptr_restrict" = 2;

      # Restrict perf events
      "kernel.perf_event_paranoid" = 3;

      # Disable unprivileged user namespaces (may break some apps)
      "kernel.unprivileged_userns_clone" = if cfg.level == "paranoid" then 0 else 1;

      # Network security
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.secure_redirects" = 0;
      "net.ipv4.conf.default.secure_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.default.accept_source_route" = 0;
      "net.ipv6.conf.all.accept_source_route" = 0;
      "net.ipv6.conf.default.accept_source_route" = 0;

      # TCP hardening
      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv4.tcp_rfc1337" = 1;
      "net.ipv4.tcp_timestamps" = 1; # Keep enabled for performance

      # Ignore ICMP broadcasts
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

      # Disable IPv6 if not needed (optional)
      # "net.ipv6.conf.all.disable_ipv6" = 1;
    };

    # Enable kernel lockdown in integrity mode
    boot.kernelParams = [
      "lockdown=integrity"
      "page_alloc.shuffle=1"
      "debugfs=off"
    ]
    ++ lib.optionals (cfg.level == "paranoid") [
      "init_on_alloc=1"
      "init_on_free=1"
      "slab_nomerge"
      "vsyscall=none"
    ];

    # Use hardened kernel (optional - may have compatibility issues)
    # boot.kernelPackages = pkgs.linuxPackages_hardened;

    # Restrict module loading after boot
    security.lockKernelModules = cfg.level == "paranoid";
  };
}
