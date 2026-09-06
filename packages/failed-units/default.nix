# failed-units: the one question the tray cannot answer - what has failed.
#
# Item 14 of docs/plans/desktop-design.md. The escalation ladder had a rung
# missing: glance should say "something is wrong", pick should say what, and
# full is journalctl. The tray covers applications that ship a tray icon and
# nothing else; a user service that dies under graphical-session.target just
# means a missing bar module and a wallpaper that did not appear.
#
# Two scripts, built on the same pattern as nixos-upgrade:
#
#   failed-units-waybar  renders nothing at all when every unit is healthy
#                        and a visible marker when any user or system unit
#                        has failed. Reading is event-free: it shells out to
#                        systemctl on an interval, which is exactly the
#                        poller principle 1 warns about - but unit failures
#                        change at human speed, so a 30s interval is far
#                        slower than the thing it watches.
#
#   failed-units-click   a rofi menu over the failed units; picking one opens
#                        its journal in the terminal. User units read
#                        `journalctl --user`; system units need journal
#                        access the user may not have, in which case the
#                        terminal says so honestly rather than hiding it.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  systemd,
  jq,
  rofi-menu,
}:
let
  status = writeShellApplication {
    name = "failed-units-waybar";
    runtimeInputs = [
      systemd
      jq
    ];
    text = ''
      user_failed="$(systemctl --user --failed --no-legend --no-pager 2>/dev/null | wc -l)"
      system_failed="$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l)"
      total="$((user_failed + system_failed))"

      if [ "$total" -eq 0 ]; then
        jq -cn --arg tooltip "All services running" \
          '{text: "", class: "ok", tooltip: $tooltip}'
      else
        jq -cn --arg n "$total" --arg tooltip "$total failed unit(s). Click to inspect." \
          '{text: "󰅙", class: "failed", tooltip: $tooltip}'
      fi
    '';
  };

  click = writeShellApplication {
    name = "failed-units-click";
    runtimeInputs = [
      systemd
      rofi-menu
    ];
    text = ''
      # Every row is SCOPE<TAB>UNIT so the journal open knows which side of
      # the user/system line the unit lives on.
      list() {
        systemctl --user --failed --no-legend --no-pager 2>/dev/null | while read -r unit _; do
          [ -n "$unit" ] && printf 'user\t%s\n' "$unit"
        done
        systemctl --failed --no-legend --no-pager 2>/dev/null | while read -r unit _; do
          [ -n "$unit" ] && printf 'system\t%s\n' "$unit"
        done
      }

      choice="$(list | rofi-menu "Failed units" 10)" || exit 1
      scope="''${choice%%$'\t'*}"
      unit="''${choice#*$'\t'}"
      [ -n "$unit" ] || exit 0

      if [ "$scope" = "user" ]; then
        exec term-run journalctl --user -u "$unit" -n 200 --no-pager
      else
        exec term-run journalctl -u "$unit" -n 200 --no-pager
      fi
    '';
  };
in
symlinkJoin {
  name = "failed-units";
  paths = [
    status
    click
  ];

  meta = {
    description = "Waybar module and journal menu for failed systemd units";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
