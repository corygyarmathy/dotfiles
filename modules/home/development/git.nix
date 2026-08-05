# Git version control
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.git;
in
{
  options.cg.home.git.enable = lib.mkEnableOption "Git configuration";

  config = lib.mkIf cfg.enable {
    programs.git = {
      enable = true;
      settings.user = {
        name = "Cory Gyarmathy";
        email = "cory.gyarmathy@gmail.com";
      };
    };

    home.packages = with pkgs; [
      git
      gh # GitHub CLI
      git-credential-manager
      dotnetCorePackages.dotnet_10.sdk
      gnupg
      pinentry-all
      pass-wayland
      lazygit
    ];
  };
}
