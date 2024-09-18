{
  lib,
  config,
  pkgs,
  ...
}:
{

  # TODO: investigate enabling this when the main cg.stylix option is enabled
  options = {
    cg.home.stylix.enable = lib.mkEnableOption "setting stylix hm settings";
  };

  config = lib.mkIf config.cg.home.stylix.enable {
    # Configure stylix in home manager (for RICEing)
    stylix = {
      targets = {
        # Disabling as I have a custom configuration
        waybar.enable = false;
        vim.enable = false; # Covers both vim and nvim
      };
    };
    home.packages = with pkgs; [
      # RICE / aesthetics
      # TODO: are these needed?
      rose-pine-gtk-theme
      rose-pine-icon-theme
    ];
  };
}
