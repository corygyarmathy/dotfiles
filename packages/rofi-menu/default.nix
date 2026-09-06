# rofi-menu: the one way this desktop asks a question with a list of answers.
#
# Item 7 of docs/plans/desktop-design.md, and the decision it rests on. Power,
# wifi, bluetooth, audio sinks, clipboard history, emoji and the keybind sheet
# are all the same shape - a list you filter by typing, pick with the keyboard
# or the pointer, and dismiss with Escape. The default answer is a different
# applet for each: wlogout, nm-applet, blueman-applet, a clipboard picker. That
# is four more processes, four more tray icons, four more themes and four more
# upstreams, to solve one problem four times.
#
# rofi already does exactly this, is already themed by a file this repository
# owns, and has been native Wayland since 2.0. So the menus are scripts over
# `nmcli`, `bluetoothctl`, `wpctl`, `cliphist` and `loginctl`, and this is the
# piece they share.
#
# THE RULES IT EXISTS TO KEEP (from the plan, restated here because this is
# where they are enforceable rather than aspirational):
#
#   - Every menu uses the same theme, with at most a size override. A power
#     menu and a wifi menu that look different are two menus, and one menu
#     system is the entire point of the item. `rows` below is the only knob,
#     and it is the only one that should ever be added.
#   - Every menu is bound *and* reachable from the bar. Principle 2 in one
#     sentence: SUPER-something from the keyboard, a click on the relevant
#     module from the pointer, and neither is the real one.
#   - A menu does one thing. The wifi menu connects to a network; it does not
#     edit connection profiles, which is `full` depth on the escalation ladder
#     and belongs to an application.
#   - A menu script that grows past about fifty lines is the wrong tool for
#     that job, and the applet should be reconsidered for that one case.
#
# The alternatives, named so they are not silently re-litigated: fuzzel and
# tofi both open faster than rofi - tofi measurably so - and are the right call
# if open time turns out to be the bottleneck now that item 22 has removed the
# 400 ms fade in front of it. walker bundles clipboard, emoji, calculator and
# window switching natively and would replace these scripts entirely, but it is
# young and moving fast, which is what principle 6 refuses. rofi stays because
# the theme already exists and scriptability is the feature being used.
{
  lib,
  writeShellApplication,
  rofi,
}:
writeShellApplication {
  name = "rofi-menu";

  # rofi comes from the closure rather than from PATH. A menu that stops
  # working because the launcher left the user's profile is exactly the class
  # of failure item 1 built a check for; here it can simply be made impossible.
  runtimeInputs = [ rofi ];

  text = ''
    # Usage: <list on stdin> | rofi-menu PROMPT [ROWS]
    #
    # Prints the chosen line on stdout. Exits 1 if the menu was dismissed,
    # which is how a caller tells "the user picked nothing" from "something
    # went wrong" - rofi uses the same convention and it is passed straight
    # through.
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
      echo "usage: <list> | rofi-menu PROMPT [ROWS]" >&2
      exit 2
    fi

    # -no-custom      a menu offers answers; typing a new one is not an answer
    # -disable-history  a menu whose order changes under you is a worse menu
    # -no-sidebar-mode  the mode switcher belongs to the launcher, not here
    #
    # Everything else - colour, radius, spacing, font - comes from the shared
    # theme in configs/rofi, which is the whole point.
    args=(-dmenu -i -p "$1" -no-custom -disable-history -no-sidebar-mode)

    # The one permitted override: how many rows to show. A menu with five
    # answers should not leave three empty rows below them.
    if [ $# -eq 2 ]; then
      args+=(-theme-str "listview { lines: $2; }")
    fi

    exec rofi "''${args[@]}"
  '';

  meta = {
    description = "Shared rofi dmenu wrapper: one theme, one interaction model, for every menu on the desktop";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "rofi-menu";
  };
}
