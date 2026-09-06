# mkMenu: the one shape a desktop menu is allowed to have.
#
# Item 7 of docs/plans/desktop-design.md made rofi the menu system and gave
# every menu the same shape - a list you filter by typing, pick with the
# keyboard or the pointer, dismiss with Escape - and then said it out loud:
# "whoever writes the second menu should extract a `mkMenu` builder and put
# the rule in it." Every menu written since (items 8, 9, 10, 13, 14 and 15 -
# the annotation prompt included) goes through this, so the rule lives here
# rather than being restated in each package's header.
#
# The rule, in one sentence: a menu is <list> piped through rofi-menu with a
# prompt and a row count, and the picked line is $choice. That is everything.
# The list and the action differ per menu; the interface between them does
# not, which is what stops the wifi menu and the power menu from drifting
# into looking like different things.
#
# One convention is baked in rather than restated: `$choice` is captured with
# `|| exit 1`, so a dismissed menu (rofi's exit 1) is indistinguishable from
# "the user changed their mind" and a caller never acts on an empty pick. A
# menu does nothing when its question is dismissed; that is the whole point
# of Escape.
{
  lib,
  writeShellApplication,
  rofi-menu,
}:
{
  name,
  prompt,
  rows,
  runtimeInputs ? [ ],
  list,
  action,
}:
writeShellApplication {
  inherit name;
  runtimeInputs = [ rofi-menu ] ++ runtimeInputs;

  text = ''
    # ${name}: item 7's menu shape. <list> emits one choice per line;
    # rofi-menu presents them with the shared theme; the picked line is
    # $choice below. Rows is the only knob a menu is allowed to turn.
    #
    # The list is wrapped in a brace group so that a multi-line list
    # generator stays one pipeline element - a bare `|| true` on its own
    # line would otherwise swallow the appended `| rofi-menu` into a
    # second pipeline that never runs.
    choice="$(
      {
        ${list}
      } | rofi-menu ${lib.escapeShellArg prompt} ${toString rows}
    )" || exit 1

    ${action}
  '';
}
