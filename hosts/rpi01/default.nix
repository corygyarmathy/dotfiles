# rpi01 - Raspberry Pi 4 Model B driving RGB LED panels
#
# ROLE: appliance (fleet/default.nix). Headless, on Wi-Fi, managed like the
# rest of the fleet but depended on by nothing.
#
# INSTALLATION - a flashed card that is fully configured on first boot:
#
#   1. Generate its SSH host key here, so its age key is known before it
#      boots and secrets/rpi01.yaml can be encrypted to it:
#        ssh-keygen -t ed25519 -N "" -C root@rpi01 -f <dir>/ssh_host_ed25519_key
#        ssh-to-age < <dir>/ssh_host_ed25519_key.pub   # -> &rpi01 in .sops.yaml
#   2. Build and flash the image (needs aarch64 emulation on the builder,
#      `boot.binfmt.emulatedSystems` on xps15):
#        nix build .#nixosConfigurations.rpi01.config.system.build.sdImage
#        zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
#   3. Mount the card's root partition (label NIXOS_SD) and copy the key pair
#      to etc/ssh/ on it - private key mode 0600, owned by root. sshd keeps an
#      existing host key, so first boot uses this one and sops-nix can decrypt.
#   4. Shred the local copy of the private key.
#
# After that it follows `deploy` like every other host.
{
  config,
  lib,
  ...
}:
{
  imports = [
    ./hardware.nix

    ../../profiles/common.nix

    # Named one by one rather than the whole of ../../modules/nixos: this host
    # is built from nixos-26.05 (fleet/default.nix), and the desktop and
    # boot-counting modules set options only unstable has. A module listed
    # here has to evaluate on both.
    ../../modules/nixos/deploy-rs.nix
    ../../modules/nixos/firewall.nix
    ../../modules/nixos/fleet.nix # `cg.fleet`, which checks read on every host
    ../../modules/nixos/kernel-hardening.nix
    ../../modules/nixos/sops-nix.nix
    ../../modules/nixos/ssh-hardening.nix
    ../../modules/nixos/stylix.nix # declares `cg.stylix`, which flake.nix reads for every host
    ../../modules/nixos/user-security.nix
    ../../modules/nixos/wireless.nix

    # By hand for the same reason: the services index would import every
    # homelab service module.
    ../../modules/services/led-matrix.nix
  ];

  # ============================================================================
  # Users
  # ============================================================================
  # Declarative and password-locked like the servers (profiles/server.nix),
  # without the rest of what being a server costs.
  users = {
    users.root.hashedPassword = "!";
    users.coryg = {
      hashedPasswordFile = config.sops.secrets."users/coryg".path;
      uid = 1000;
    };
    mutableUsers = false;
  };
  sops.secrets."users/coryg".neededForUsers = true;

  # ============================================================================
  # Auto-Upgrade
  # ============================================================================
  # Follows `deploy` like every host. CI builds this closure on an arm64 runner
  # and pushes it to Cachix, so this substitutes rather than compiling. Reboots
  # with no boot counting or upgrade-verify behind it: ADR 0009 accepts that
  # for an appliance.
  system.autoUpgrade = {
    enable = true;
    flake = "github:corygyarmathy/dotfiles/deploy#${config.networking.hostName}";
    dates = "04:30";
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "05:00";
    };
    randomizedDelaySec = "10min";
  };

  # ============================================================================
  # Module Toggles
  # ============================================================================
  cg = {
    sops-nix = {
      enable = true;
      # Reads nothing it shares with the servers: its copy of `users/coryg`
      # lives in secrets/rpi01.yaml, so it is never a recipient of
      # shared.yaml and its backup and alerting credentials.
      sharedSecrets = [ ];
    };
    wireless = {
      enable = true;
      networks = [ "Wireless" ];
    };
    ssh-hardening = {
      enable = true;
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGN2/Vvyb3abKAxdCYt9pxGgOho5uqtNzhpXVxGVw1gq coryg@xps15"
      ];
    };
    deploy-rs = {
      enable = true;
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEptc3aZw3UltEoKboluqNvpFsYmirJxaoZg3AM3eB6f deploy@xps15"
      ];
    };
    kernel-hardening = {
      enable = true;
      level = "desktop";
    };
    firewall.enable = true;
    user-security.enable = true;

    # Four 64x64 panels in a row on the Adafruit RGB Matrix Bonnet, a 256x64
    # canvas. The bonnet has GPIO4 bridged to GPIO18 for hardware pulsing,
    # hence the -pwm mapping. The module relaxes /dev/mem for it (ADR 0010).
    # Showing the demo until there is content.
    #
    # Slowdown 2 and 3 sparkle at the full 1500 MHz clock; 4 is clean, and
    # with hardware pulsing it costs almost no refresh (~100 Hz either way).
    # The PWM flags stay at the library defaults: 11-bit colour at ~100 Hz
    # showed no visible flicker, so nothing was worth trading for more.
    # This only holds while the Pi is not undervoltage-throttled - see
    # hardware.nix for the power wiring.
    service.led-matrix = {
      enable = true;
      gpioMapping = "adafruit-hat-pwm";
      rows = 64;
      cols = 64;
      chain = 4;
      slowdownGpio = 4;
    };
  };

  system.stateVersion = "26.05";
}
