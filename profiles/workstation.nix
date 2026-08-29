# What it costs to be a machine someone sits in front of.
#
# There is one workstation in this fleet today, so nothing here yet removes a
# duplicate the way ./server.nix does. It exists so that the xps15 host file is
# about the XPS 15 - its screens, its thermals, its GPU, what it is used for -
# rather than about the fact that a desktop needs an audio server and a way to
# mount a USB stick. The test for whether something belongs here is whether the
# next laptop would want it without being asked.
#
# Read ./common.nix first: the rule that a profile has no options applies here
# too. Anything tied to a `cg.*` toggle - i2c for ddcutil, input for the
# ergodox, docker for docker - stays with the toggle in the host file.
#
# Imported alongside ./common.nix, not instead of it.
{ pkgs, ... }:
{
  # ============================================================================
  # Accounts
  # ============================================================================
  # A person at the keyboard changes networks; a server does not.
  users.users.coryg.extraGroups = [ "networkmanager" ];

  # ============================================================================
  # Audio
  # ============================================================================
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ============================================================================
  # Desktop plumbing
  # ============================================================================
  services.dbus.enable = true;
  systemd.user.services.dbus = {
    enable = true;
    wantedBy = [ "default.target" ];
  };

  # USB auto-mounting
  services.gvfs.enable = true;
  services.udisks2.enable = true;

  # Printing, and finding printers on the LAN
  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # ============================================================================
  # Input
  # ============================================================================
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # ============================================================================
  # Keys
  # ============================================================================
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };
  services.pcscd.enable = true;

  # ============================================================================
  # Programs
  # ============================================================================
  # Allow dynamically linked executables - language servers and downloaded
  # tooling assume an FHS-ish loader, and a workstation is where those run.
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc
      libGL
    ];
  };
}
