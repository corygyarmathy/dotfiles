# nvim.nix

{
  pkgs,
  lib,
  config,
  ...
}:
let

  # FIXME: fix this script
  # Hyprscade config script - I feel like this doesn't work
  hyprshade-script = pkgs.pkgs.writeShellScriptBin "hyprshade-script" ''
     	 hyprshade install
    	 systemctl --user enable --now hyprshade.timer
    	 
    	 sleep 1 

    	 hyprshade auto
  '';
in
{

  options = {
    cg.home.hyprshade.enable = lib.mkEnableOption "enables hyprshade";
  };

  config = lib.mkIf config.cg.home.hyprshade.enable {
    # TODO: Redo this using Home-Manager options
    # Configure Hyprshade profiles (blue light filter)
    # TODO: split into separate module
    home.file.".config/hypr/hyprshade.toml".text = ''
      [[shades]]
      name = "vibrance"
      default = true  # shader to use during times when there is no other shader scheduled

      [[shades]]
      name = "blue-light-filter"
      start_time = 19:00:00
      end_time = 06:00:00   # optional if you have more than one shade with start_time
    '';

    home.packages = with pkgs; [
      hyprshade # Used for 'night mode' blue light filter
      # Custom Scripts
      hyprshade-script # I don't think this works... need to investigate further
    ];
  };
}
