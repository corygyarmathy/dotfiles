# What it costs to be a machine in this fleet.
#
# The distinction from ../modules: a module offers an option and does nothing
# until a host enables it; a profile makes a decision and offers nothing.
# `cg.boot-counting` is a module. "This fleet keeps its clocks in Perth" is a
# profile.
#
# THE RULE THAT KEEPS THIS FROM BECOMING A SECOND MODULE SYSTEM: a profile has
# no options. If something here has to differ per host, it is a module and
# belongs in ../modules; if it differs because of the hardware, it belongs in
# that host's hardware.nix. Nothing in this directory decides anything by
# looking at `config.networking.hostName`.
#
# Imported by every host. ./server.nix and ./workstation.nix sit on top of this
# file and are imported alongside it, not instead of it.
{ pkgs, ... }:
{
  # ============================================================================
  # Boot
  # ============================================================================
  # Every machine here is UEFI and boots with systemd-boot. `cg.boot-counting`
  # writes its counters into systemd-boot entry filenames, so this is not only a
  # preference: that module has nowhere to write without it.
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  # ============================================================================
  # Networking
  # ============================================================================
  # NetworkManager everywhere, servers included: their addresses are DHCP
  # reservations rather than static configuration (see fleet/default.nix), so
  # there is nothing for a second backend to buy.
  networking.networkmanager.enable = true;

  # ============================================================================
  # Localisation
  # ============================================================================
  time.timeZone = "Australia/Perth";
  i18n = {
    defaultLocale = "en_GB.UTF-8";
    extraLocaleSettings = {
      LC_ADDRESS = "en_AU.UTF-8";
      LC_IDENTIFICATION = "en_AU.UTF-8";
      LC_MEASUREMENT = "en_AU.UTF-8";
      LC_MONETARY = "en_AU.UTF-8";
      LC_NAME = "en_AU.UTF-8";
      LC_NUMERIC = "en_AU.UTF-8";
      LC_PAPER = "en_AU.UTF-8";
      LC_TELEPHONE = "en_AU.UTF-8";
      LC_TIME = "en_AU.UTF-8";
    };
  };

  # ============================================================================
  # The one human account
  # ============================================================================
  # Only what is true on every machine. How the account authenticates, and which
  # groups it needs, follow from what the machine is for and are set by the
  # profile for that kind of machine.
  users.users.coryg = {
    description = "Cory Gyarmathy";
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  # ============================================================================
  # Terminfo
  # ============================================================================
  # Ghostty advertises TERM=xterm-ghostty, and any machine in this fleet is a
  # possible SSH target, so every one of them must be able to resolve that
  # terminal name. systemPackages is what makes it work: its share/terminfo is
  # collated into /run/current-system/sw/share/terminfo, and NixOS login shells
  # export TERMINFO_DIRS with that path via /etc/set-environment - the same
  # mechanism that supplies xterm-256color from ncurses. This covers interactive
  # SSH and sudo; a non-interactive `ssh host 'command'` does not read
  # /etc/set-environment.
  environment.systemPackages = [ pkgs.ghostty.terminfo ];

  # ============================================================================
  # Environment
  # ============================================================================
  environment.sessionVariables = {
    EDITOR = "nvim";
    GIT_EDITOR = "nvim";
  };
}
