# audio-menu: switch the default sink or source, from a menu.
#
# Item 9 of docs/plans/desktop-design.md. Switching audio devices meant
# opening pavucontrol - a full mixer - for a question that is "which
# headphones". This is that question, over wpctl: a list of sinks and
# sources, and picking one makes it the default.
#
# Parsing `wpctl status` is the fragile half and deserves the note: the
# output is a tree drawn in Unicode box characters, and the only stable part
# of a line is the `NN. name` after it. The awk strips everything up to the
# node id, reads the id and the name, and drops the `[vol: ...]` annotation
# that is not part of the name.
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
  name = "audio-menu";
  prompt = "Audio";
  rows = 10;

  runtimeInputs = [
    pkgs.pipewire # wpctl
  ];

  # Sinks first, sources second, each row `ICON NAME<TAB>ID`. PipeWire node
  # ids are unique across sinks and sources, so `wpctl set-default` needs
  # only the id and the kind of the row does not matter to it.
  list = ''
    {
      wpctl status 2>/dev/null | awk '
        /Sinks:/ { section = "sink"; next }
        /Sources:/ { section = "source"; next }
        /Streams:/ { section = ""; next }
        /Aux\// { section = ""; next }
        section == "" { next }
        {
          line = $0
          sub(/^[^0-9]*/, "", line)
          if (line !~ /^[0-9]+\./) next
          id = line
          sub(/\..*/, "", id)
          name = line
          sub(/^[0-9]+\. /, "", name)
          sub(/[[:space:]]*\[.*$/, "", name)
          if (name == "") next
          if (section == "sink") printf "󰓃 %s\t%s\n", name, id
          else printf " %s\t%s\n", name, id
        }'
    }
  '';

  action = ''
    id="''${choice#*$'\t'}"
    [ -n "$id" ] || exit 0
    wpctl set-default "$id"
  '';
}
