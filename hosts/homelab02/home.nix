# Homelab02 - Home-manager configuration for coryg
# Minimal server profile: shell prompt + core CLI tools
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    # Home-manager modules (shared with desktop)
    ../../modules/home
  ];

  # ============================================================================
  # Module Toggles
  # ============================================================================
  cg.home = {
    # Shell
    starship.enable = true;

    # Development (reuse your shared configs)
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
