# wezterm.nix

{
  lib,
  config,
  pkgs,
  inputs,
  ...
}:
{

  options = {
    cg.home.wezterm.enable = lib.mkEnableOption "enables wezterm";
  };

  config = lib.mkIf config.cg.home.wezterm.enable {
    # wezterm config (terminal editor)
    programs.wezterm = {
      enable = true;
      package = inputs.wezterm.packages.${pkgs.system}.default;
    };

    home.packages = with pkgs; [
      # wezterm
    ];
  };
}
