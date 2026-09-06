# The build gate for swayosd's stylesheet.
#
# Item 12 of docs/plans/desktop-design.md gives swayosd the same three gates
# the bar and the launcher sit behind, so it joins the palette scheme rather
# than arriving as a fourth hand-written copy: the generated-file gate (the
# checked-in copy under configs/ must match lib/kanagawa-wave.nix), the
# geometry gate (its lengths must be on the scale), and this one - a
# stylesheet GTK 4 will not parse is an OSD that silently looks default,
# because swayosd warns and carries on. See ../swayosd-css-parse.py.
{ pkgs }:
let
  # Same shape as lib/gtk-css.nix but for GTK 4, which is what swayosd hands
  # its stylesheet to. Parsing needs no display, but it does need the typelibs
  # on GI_TYPELIB_PATH and nothing else.
  typelibs = pkgs.lib.makeSearchPathOutput "out" "lib/girepository-1.0" (
    with pkgs;
    [
      gtk4
      glib
      graphene
      pango
      gdk-pixbuf
      harfbuzz
      gobject-introspection
    ]
  );
in
pkgs.writeShellApplication {
  name = "swayosd-css-parse";
  runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.pygobject3 ])) ];
  text = ''
    export GI_TYPELIB_PATH=${typelibs}
    export FONTCONFIG_FILE=${pkgs.fontconfig.out}/etc/fonts/fonts.conf

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cp "$@" "$work"/

    names=()
    for file in "$@"; do
      names+=("$work/$(basename "$file")")
    done

    HOME=$work exec python3 ${../swayosd-css-parse.py} "''${names[@]}"
  '';
}
