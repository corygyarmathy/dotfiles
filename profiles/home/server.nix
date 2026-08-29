# Home-manager configuration for coryg on a server.
#
# Minimal server profile: shell prompt and core CLI tools, no desktop. This was
# two byte-identical files, hosts/homelab01/home.nix and hosts/homelab02/
# home.nix, differing only in the comment on line 1. It is wired up by
# ../server.nix rather than by either host.
{ ... }:
{
  imports = [
    # Home-manager modules (shared with the desktop)
    ../../modules/home
  ];

  # ============================================================================
  # Module Toggles
  # ============================================================================
  cg.home = {
    # Shell
    starship.enable = true;

    # Development (reuse the shared configs)
    git.enable = true;
    nvim.enable = true;
  };

  # ============================================================================
  # User Info
  # ============================================================================
  home = {
    username = "coryg";
    homeDirectory = "/home/coryg";
    stateVersion = "24.11";
  };

  # ============================================================================
  # Enable Home Manager
  # ============================================================================
  programs.home-manager.enable = true;
}
