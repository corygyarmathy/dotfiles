# keybind-sheet: the documentation binds.lua never had.
#
# Item 11 of docs/plans/desktop-design.md. Around sixty bindings across nine
# labelled sections, and no way to see them except by opening the file - which
# makes a keyboard-first desktop keyboard-first only for the bindings already
# memorised, and the eight new menus this plan adds are eight more things to
# forget. SUPER+slash shows them all.
#
# It reads the *deployed* binds.lua, so it shows what is actually bound rather
# than a hand-maintained copy that drifts. If the parse ever breaks, the
# failure is a sheet that does not open - not a system failure - and the build
# gates the same parse over the checked-in file so that cannot happen at
# runtime without being noticed at build time first.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  rofi-menu,
  python3,
}:
let
  # The sheet itself: parse the *deployed* binds.lua and present it in rofi.
  sheet = writeShellApplication {
    name = "keybind-sheet";
    runtimeInputs = [
      rofi-menu
      python3
    ];

    text = ''
      exec python3 ${./keybind-sheet.py} | rofi-menu "Keybinds" 20
    '';
  };

  # The same parser, as a command a build gate can call: prints the sheet and
  # fails if the file cannot be parsed or yields no binds at all. hyprland.nix
  # runs this over the checked-in binds.lua, so a file the sheet stops
  # understanding fails the build instead of silently losing its
  # documentation - the half of this package's contract that cannot wait for
  # runtime to notice.
  parse = writeShellApplication {
    name = "keybind-sheet-parse";
    runtimeInputs = [ python3 ];

    text = ''
      out="$(python3 ${./keybind-sheet.py} "$1")" || exit 1
      [ -n "$out" ] || {
        echo "keybind-sheet-parse: no binds parsed from '$1'" >&2
        exit 1
      }
      printf '%s\n' "$out"
    '';
  };
in
symlinkJoin {
  name = "keybind-sheet";
  paths = [
    sheet
    parse
  ];

  meta = {
    description = "Rofi keybind reference parsed from binds.lua";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "keybind-sheet";
  };
}
