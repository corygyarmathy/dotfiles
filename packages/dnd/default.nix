# dnd: do-not-disturb's two surfaces - the bar module and the history menu.
#
# Item 13 of docs/plans/desktop-design.md. Principle 3's off switch did not
# exist: dunst can be paused and nothing offered it, and the twenty
# notifications it keeps in history had no way in. Two scripts:
#
#   dnd-waybar   reports whether dunst is paused, so the bar can show the
#                state - and change shape, not just colour, when it is on,
#                because a do-not-disturb that can be left on silently is a
#                worse failure than not having one.
#
#   dnd-history  a rofi menu over dunst's history; picking an entry pops it,
#                which re-displays the notification the user missed.
#
# Both read from dunst itself rather than keeping state, so the module cannot
# drift from what is actually true.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  dunst,
  jq,
  rofi-menu,
}:
let
  mkMenu = import ../lib/mk-menu.nix {
    inherit lib writeShellApplication rofi-menu;
  };

  status = writeShellApplication {
    name = "dnd-waybar";
    runtimeInputs = [
      dunst
      jq
    ];
    text = ''
      if [ "$(dunstctl is-paused)" = "true" ]; then
        jq -cn --arg tooltip "Do not disturb is on - notifications are paused. Click to turn it off." \
          '{text: "󰂛 DND", class: "paused", tooltip: $tooltip}'
      else
        jq -cn --arg tooltip "Do not disturb is off. Click to pause notifications." \
          '{text: "󰂛", class: "on", tooltip: $tooltip}'
      fi
    '';
  };

  # The history view, as item 7's menu shape. dunstctl history is JSON here -
  # an array of arrays of notifications - and every value is itself wrapped
  # as {type, data}. The jq unwraps both and cuts the body to a preview, and
  # the row is ID<TAB>summary<TAB>body so the id survives the menu.
  # history-pop re-displays the picked notification in full.
  history = mkMenu {
    name = "dnd-history";
    prompt = "Notification history";
    rows = 12;
    runtimeInputs = [
      dunst
      jq
    ];
    list = ''
      dunstctl history | jq -r '.data[][] | "\(.id.data)\t\(.summary.data // "")\t\(((.body.data // "") | .[0:80]))"'
    '';
    action = ''
      id="''${choice%%$'\t'*}"
      [ -n "$id" ] || exit 0
      dunstctl history-pop "$id"
    '';
  };
in
symlinkJoin {
  name = "dnd";
  paths = [
    status
    history
  ];

  meta = {
    description = "Do-not-disturb bar module and notification history menu for dunst";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
