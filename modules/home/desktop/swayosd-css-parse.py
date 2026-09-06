"""Ask GTK 4 whether it can parse swayosd's stylesheet.

swayosd loads ~/.config/swayosd/style.css with GTK 4's CSS parser and only
warns when it fails - a file GTK rejects is an OSD that silently looks
default, which is the same failure mode as a rofi theme that does not parse.
GTK's parser is narrower than CSS on the web, so "does the file match the
palette" and "do its lengths sit on the scale" are both necessary and neither
is sufficient; the file also has to be something GTK accepts. This is that
check, run at build time on the file swayosd will actually read.

The GTK 3 equivalent for waybar is gtk-css-parse.py; swayosd is GTK 4, whose
parser is strict enough that this earns its keep separately. See
../lib/swayosd-css.nix for the wrapper that supplies the typelibs.
"""

import os
import sys

import gi

gi.require_version("Gtk", "4.0")

from gi.repository import GLib, Gtk  # noqa: E402


def errors_in(path):
    found = []

    def on_error(_provider, section, error):
        # The section names the file the error is *in*, which is not `path`
        # when the mistake is inside an @import. Only the basename is useful:
        # these are copies in a build sandbox, and the name is what swayosd
        # would print anyway.
        where = section.get_file()
        name = os.path.basename(where.get_path() if where is not None else path)
        found.append(
            f"{name}:{section.get_start_line() + 1}:"
            f"{section.get_start_position() + 1}: {error.message}"
        )

    provider = Gtk.CssProvider()
    provider.connect("parsing-error", on_error)
    try:
        provider.load_from_path(path)
    except GLib.Error as exc:
        if not found:
            found.append(f"{os.path.basename(path)}: {exc.message}")

    return found


def main(paths):
    failures = list(dict.fromkeys(line for path in paths for line in errors_in(path)))
    if not failures:
        return 0

    print(
        "GTK 4 cannot parse these stylesheets, so swayosd would fall back to its default:",
        file=sys.stderr,
    )
    print(file=sys.stderr)
    for line in failures:
        print(f"    {line}", file=sys.stderr)
    print(file=sys.stderr)
    print(
        "swayosd only warns and keeps its default theme, which is why this is",
        file=sys.stderr,
    )
    print(
        "checked at build time rather than discovered on the desktop.", file=sys.stderr
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
