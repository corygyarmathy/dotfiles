# screenshot: the full screenshot suite under Print.
#
# Item 15 of docs/plans/desktop-design.md. One binding used to exist - Print
# ran `grimblast copy area` - and there was no way to save to a file, capture
# a window or a monitor, annotate, or pick a colour. This is the full set,
# with the region-to-clipboard case kept exactly as it was.
#
# Annotation is a second decision, so it is offered rather than forced: the
# save modes ask once (via rofi-menu, of course) and a dismissed prompt means
# "save it as it is", never a captured frame that vanished. hyprpicker lives
# on its own binding rather than in this script.
#
# Files land in ~/Pictures/screenshots, which is where the machine's
# documentation images are already written from.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  grimblast,
  satty,
  coreutils,
  rofi-menu,
}:
let
  mkMenu = import ../lib/mk-menu.nix {
    inherit lib writeShellApplication rofi-menu;
  };

  # The annotation decision, as item 7's menu shape. "Annotate in satty" is
  # the only entry with an action; a dismissed prompt and "Save without
  # annotating" both mean "save it as it is", never a captured frame that
  # vanished. The file being annotated arrives as $1.
  annotate = mkMenu {
    name = "screenshot-annotate";
    prompt = "Screenshot";
    rows = 2;
    runtimeInputs = [ satty ];
    list = ''
      printf 'Save without annotating\nAnnotate in satty\n'
    '';
    action = ''
      case "$choice" in
        "Annotate in satty")
          exec satty --filename "$1" --output-filename "$1"
          ;;
      esac
    '';
  };

  main = writeShellApplication {
    name = "screenshot";
    runtimeInputs = [
      grimblast
      coreutils
    ];

    text = ''
      # Usage: screenshot (area-copy|area-save|window|monitor)
      mode="''${1:?usage: screenshot (area-copy|area-save|window|monitor)}"
      dir="''${XDG_PICTURES_DIR:-$HOME/Pictures}/screenshots"
      mkdir -p "$dir"
      file="$dir/screenshot-$(date +%Y%m%d-%H%M%S).png"

      case "$mode" in
        area-copy)
          # The common case, unchanged from the original single binding.
          exec grimblast copy area
          ;;
        area-save)
          grimblast save area "$file"
          ;;
        window)
          grimblast copysave active "$file"
          ;;
        monitor)
          grimblast copysave output "$file"
          ;;
        *)
          echo "usage: screenshot (area-copy|area-save|window|monitor)" >&2
          exit 64
          ;;
      esac

      # Annotation, offered not forced (see ../lib/mk-menu.nix and the
      # annotate script above). A dismissed prompt is "save it as is".
      screenshot-annotate "$file" || true
    '';
  };
in
symlinkJoin {
  name = "screenshot";
  paths = [
    main
    annotate
  ];

  meta = {
    description = "grimblast screenshot suite with optional satty annotation";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "screenshot";
  };
}
