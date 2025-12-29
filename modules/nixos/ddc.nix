# DDC/CI monitor brightness control
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cg.ddc;
in {
  options.cg.ddc.enable = lib.mkEnableOption "DDC/CI monitor brightness control";

  config = lib.mkIf cfg.enable {
    hardware.i2c.enable = true;

    environment.systemPackages = with pkgs; [
      ddcutil
      ddcui
    ];
  };
}
