# The build gate for waybar's stylesheets.
#
# The fourth gate on the bar, and the one the other three left room for. Item
# 1's check asks whether the commands the bar names exist; item 5's asks
# whether the colour file still matches the palette; item 6's asks whether the
# lengths honour the scale. None of them asks the question waybar actually
# asks at startup, which is whether GTK can parse the file at all - and a
# stylesheet GTK rejects is not a bar that looks wrong, it is a bar that does
# not appear.
#
# So this hands the stylesheets to GTK itself, at build time, and a file GTK
# will not parse fails `nixos-rebuild switch` and fails CI. See
# ../gtk-css-parse.py for what it reports.
{ pkgs }:
let
  # Parsing CSS needs no display, but it does need the GTK typelib and every
  # other typelib GTK's introspection data refers to. Having the libraries on
  # PATH is not enough - pygobject finds typelibs by this variable alone.
  typelibs = pkgs.lib.makeSearchPathOutput "out" "lib/girepository-1.0" (
    with pkgs;
    [
      gtk3
      glib
      pango
      gdk-pixbuf
      atk
      harfbuzz
      at-spi2-core
      gobject-introspection
    ]
  );
in
pkgs.writeShellApplication {
  name = "gtk-css-parse";
  runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.pygobject3 ])) ];
  text = ''
    export GI_TYPELIB_PATH=${typelibs}
    # GTK pulls in pango, which looks for fontconfig's configuration whether
    # or not anything is going to be drawn, and grumbles to stderr when the
    # sandbox has none. Nothing here renders text; this just keeps the build
    # log about the stylesheets.
    export FONTCONFIG_FILE=${pkgs.fontconfig.out}/etc/fonts/fonts.conf

    # GTK resolves @import against the importing file's directory, and
    # style.css imports one stylesheet this module does not own: modifiers.css
    # is written by waybar-modifiers.nix at activation time and is not in
    # configs/. Checking a copy lets an empty stand-in sit beside it, so the
    # import resolves and the check is about syntax rather than about which
    # module supplies which file.
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cp "$@" "$work"/
    : > "$work"/modifiers.css

    names=()
    for file in "$@"; do
      names+=("$work/$(basename "$file")")
    done

    # HOME so fontconfig has somewhere to write its cache.
    HOME=$work exec python3 ${../gtk-css-parse.py} "''${names[@]}"
  '';
}
