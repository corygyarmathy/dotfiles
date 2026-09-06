# clipboard-menu: the clipboard history that survives its window.
#
# Item 10 of docs/plans/desktop-design.md. Under Wayland the clipboard is
# owned by the source window, so copying from a terminal and closing it lost
# the copy - a papercut that fires several times a day. cliphist stores
# history (and, by way of wl-clipboard's CLIPBOARD_STATE, skips offers
# carrying the secret hint that password managers set); wl-clip-persist keeps
# the current selection alive beyond its source window; this menu recalls
# history. SUPER+SHIFT+V.
#
# cliphist list already emits ID<TAB>preview, which is exactly the shape
# rofi-menu wants, and cliphist decode turns the picked id back into the
# original byte-for-byte selection, which wl-copy restores to the clipboard.
{
  lib,
  pkgs,
}:
let
  mkMenu = import ../lib/mk-menu.nix {
    inherit lib;
    writeShellApplication = pkgs.writeShellApplication;
    rofi-menu = pkgs.rofi-menu;
  };
in
mkMenu {
  name = "clipboard-menu";
  prompt = "Clipboard";
  rows = 12;

  runtimeInputs = [
    pkgs.cliphist
    pkgs.wl-clipboard # wl-copy, to put the picked item back on the clipboard
  ];

  list = ''
    cliphist list
  '';

  action = ''
    printf '%s\n' "$choice" | cliphist decode | wl-copy
  '';
}
