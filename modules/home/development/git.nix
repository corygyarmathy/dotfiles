# Git version control
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.home.git;
in {
  options.cg.home.git.enable = lib.mkEnableOption "Git configuration";

  config = lib.mkIf cfg.enable {
    programs.git = {
      enable = true;
      userName = "Cory Gyarmathy";
      userEmail = "cory.gyarmathy@gmail.com";
    };

    home.packages = with pkgs; [
      git
      gh # GitHub CLI
      git-credential-manager
      dotnetCorePackages.sdk_8_0_3xx
      gnupg
      pinentry-all
      pass-wayland
      lazygit
    ];
  };
}
