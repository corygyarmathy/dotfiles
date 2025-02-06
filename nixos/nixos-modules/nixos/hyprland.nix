{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
{
  options = {
    cg.hyprland.enable = lib.mkEnableOption "enables hyprland";
  };

  config = lib.mkIf config.cg.hyprland.enable {
    # Hyprland config
    # TODO: enable this only if the Nvidia module / option is also enabled
    boot.kernelParams = [
      "nvidia-drm.modeset=1" # Used for Wayland compat.
      "nvidia-drm.fbdev=1" # Used for Wayland compat.
      "nvidia.NVreg_PreserveVideoMemoryAllocations=1" # Addresses Nvidia sleep issues
    ];

    # Set up display / login manager for Hyprland
    # NOTE: disabling, as it seems to cause a lot of weird issues
    # TODO: look into launching hyprland after logging into tty automatically

    # services.xserver = {
    #   enable = true;
    #   videoDrivers = [ "nvidia" ];
    #   displayManager.gdm = {
    #     enable = true;
    #     wayland = true;
    #   };
    # };

    # Enable the Hyprland compositor
    # Refer to: https://wiki.hyprland.org/Nix/Hyprland-on-NixOS/
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
      # Ensures you're using the most up-to-date package
      # package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
      # Make sure to also set the portal package, so that they are in sync
      # portalPackage =
      # inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
    };

    environment.sessionVariables = {
      # Required for Hyprland on Nvidia
      WLR_NO_HARDWARE_CURSORS = "1"; # If your cusor becomes inviseble
      NIXOS_OZONE_WL = "1"; # Hint Electron apps to use Wayland
      LIBVA_DRIVER_NAME = "nvidia";
      XDG_SESSION_TYPE = "wayland";
      GBM_BACKEND = "nvidia-drm";
    };

    # Required for Wayland / Hyprland
    security.polkit.enable = true;

    environment.systemPackages = with pkgs; [
      xdg-desktop-portal-hyprland # Req. for Hyprland # xdg-desktop-portal backend for Hyprland
      # xdg-desktop-portal-gtk # Req. for Hyprland # filepicker for XDPH # Removing, known issues with hyprland
      egl-wayland # Required in order to enable compatibility between the EGL API and the Wayland protocol
      qt5.qtwayland # Required for Wayland / Hyprland
      qt6.qtwayland # Required for Wayland / Hyprland
    ];
  };
}
