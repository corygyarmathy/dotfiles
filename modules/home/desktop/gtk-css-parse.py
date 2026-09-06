"""Ask GTK whether it can parse waybar's stylesheets.

waybar hands its CSS to GTK 3 and exits 1 if GTK complains, so a stylesheet
that does not parse is not a bar with the wrong colours - it is no bar at all.
GTK's parser is also narrower than CSS on the web: `#RRGGBBAA` is not a
translucent colour there, it is "Missing semicolon at end of color definition",
and the error aborts the rest of the file.

Nothing else in the build was in a position to notice. The generated-file gate
checks the stylesheet is byte-for-byte what lib/kanagawa-wave.nix produces,
which it was; the geometry gate reads it with a regex, which does not care
whether GTK agrees. Both pass on a file GTK rejects. So this one does the only
thing that settles it and hands the file to GTK.

Every error is reported rather than just the first, because GTK keeps parsing
after one and a second mistake would otherwise take a second round trip. They
are reported by basename, in `style.css:15:24` form, so that what this prints
and what waybar prints when it gives up are the same string.
"""

import os
import sys

import gi

gi.require_version("Gtk", "3.0")

from gi.repository import GLib, Gtk  # noqa: E402  (must follow require_version)


def errors_in(path):
    """Return GTK's complaints about one stylesheet, as printable lines."""
    found = []

    def on_error(_provider, section, error):
        # The section names the file the error is *in*, which is not `path`
        # when the mistake is inside an @import. Only the basename is useful:
        # these are copies in a build sandbox, and the name is what waybar
        # would print anyway.
        where = section.get_file()
        name = os.path.basename(where.get_path() if where is not None else path)
        # GTK counts lines and columns from zero; editors and waybar's own
        # log do not.
        found.append(
            f"{name}:{section.get_start_line() + 1}:"
            f"{section.get_start_position() + 1}: {error.message}"
        )

    provider = Gtk.CssProvider()
    provider.connect("parsing-error", on_error)
    try:
        provider.load_from_path(path)
    except GLib.Error as exc:
        # load_from_path raises on the first error as well as signalling it.
        # The signal is the better report; this is the fallback for the case
        # where it somehow did not fire.
        if not found:
            found.append(f"{os.path.basename(path)}: {exc.message}")

    return found


def main(paths):
    # A stylesheet named here is usually also reached through style.css's
    # @import, and GTK reports the same mistake once down each route.
    # dict.fromkeys is the order-preserving way to say "once each".
    failures = list(dict.fromkeys(line for path in paths for line in errors_in(path)))
    if not failures:
        return 0

    print("GTK cannot parse these stylesheets, so waybar would not start:", file=sys.stderr)
    print(file=sys.stderr)
    for line in failures:
        print(f"    {line}", file=sys.stderr)
    print(file=sys.stderr)
    print("GTK 3 CSS is narrower than CSS on the web. In particular it has no", file=sys.stderr)
    print("eight-digit hex: write an opacity as alpha(#RRGGBB, 0.8) instead.", file=sys.stderr)
    print(file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
