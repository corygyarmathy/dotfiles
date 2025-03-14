{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    cg.ergodox.enable = lib.mkEnableOption "enables ergodox";
  };

  config = lib.mkIf config.cg.ergodox.enable {
    # Example command to flash firmware: wally-cli ./moonlander_colemak-dh-moonlander_PqOZL_a4eOO.bin

    # udev rule req. to flash firmware, and do live training
    services.udev.extraRules = ''
      # Rules for Oryx web flashing and live training
      KERNEL=="hidraw*", ATTRS{idVendor}=="16c0", MODE="0664"
      KERNEL=="hidraw*", ATTRS{idVendor}=="3297", MODE="0664"

      # Legacy rules for live training over webusb (Not needed for firmware v21+)
        # Rule for all ZSA keyboards
        SUBSYSTEM=="usb", ATTR{idVendor}=="3297"
        # Rule for the Moonlander
        SUBSYSTEM=="usb", ATTR{idVendor}=="3297", ATTR{idProduct}=="1969"
        # Rule for the Ergodox EZ
        SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="1307"
        # Rule for the Planck EZ
        SUBSYSTEM=="usb", ATTR{idVendor}=="feed", ATTR{idProduct}=="6060"

      # Wally Flashing rules for the Ergodox EZ
      ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", ENV{ID_MM_DEVICE_IGNORE}="1"
      ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789A]?", ENV{MTP_NO_PROBE}="1"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789ABCD]?", MODE:="0666"
      KERNEL=="ttyACM*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", MODE:="0666"

      # Keymapp / Wally Flashing rules for the Moonlander and Planck EZ
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE:="0666", SYMLINK+="stm32_dfu"
      # Keymapp Flashing rules for the Voyager
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="3297", MODE:="0666", SYMLINK+="ignition_dfu"
    '';

    environment.systemPackages = with pkgs; [
      libusb1 # Dependency
      wally-cli # CLI to flash firmware
    ];
  };
}
