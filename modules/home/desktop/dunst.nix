# Dunst notification daemon
# Note: Font and colors are managed by Stylix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.dunst;
in
{
  options.cg.home.dunst.enable = lib.mkEnableOption "Dunst notification daemon";

  config = lib.mkIf cfg.enable {
    services.dunst = {
      enable = true;
      settings = {
        global = {
          # Display settings
          monitor = 0;
          follow = "mouse";

          # Geometry
          width = 300;
          height = 300;
          origin = "top-right";
          offset = "10x50";

          # Progress bar
          progress_bar = true;
          progress_bar_height = 10;
          progress_bar_frame_width = 1;
          progress_bar_min_width = 150;
          progress_bar_max_width = 300;

          # Appearance (non-color/font - those are set by Stylix)
          transparency = 10;
          separator_height = 2;
          padding = 8;
          horizontal_padding = 8;
          frame_width = 2;
          corner_radius = 10;
          sort = "yes";

          # Text layout (font is set by Stylix)
          line_height = 0;
          markup = "full";
          format = "<b>%s</b>\\n%b";
          alignment = "left";
          vertical_alignment = "center";
          show_age_threshold = 60;
          ellipsize = "middle";
          ignore_newline = "no";
          stack_duplicates = true;
          hide_duplicate_count = false;
          show_indicators = "yes";

          # Icons
          icon_position = "left";
          min_icon_size = 0;
          max_icon_size = 32;

          # History
          sticky_history = "yes";
          history_length = 20;

          # Misc
          browser = "xdg-open";
          always_run_script = true;
          title = "Dunst";
          class = "Dunst";

          # Mouse actions
          mouse_left_click = "close_current";
          mouse_middle_click = "do_action, close_current";
          mouse_right_click = "close_all";
        };

        # Timeouts only - colors are set by Stylix
        urgency_low = {
          timeout = 5;
        };

        urgency_normal = {
          timeout = 10;
        };

        urgency_critical = {
          timeout = 0;
        };
      };
    };

    home.packages = with pkgs; [
      libnotify # For notify-send command
    ];
  };
}
