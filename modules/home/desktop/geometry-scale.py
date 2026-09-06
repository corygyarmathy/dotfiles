"""Assert that every length a hand-written config names is on the geometry scale.

Item 6 of docs/plans/desktop-design.md gave the desktop one scale: two radii,
one border width, and spacing in multiples of eight. Three of the files that
have to honour it - waybar's style.css, rofi's theme, hyprland's settings.lua -
are deployed verbatim so they keep working without Nix, so they cannot read the
scale. This reads them instead, and turns "everything agrees" from a thing
somebody remembers into a thing the build knows.

Scope, deliberately narrow: the properties that carry *geometry*, listed below.
Font sizes, icon sizes, opacities, transition durations and content widths are
somebody else's decision and are not looked at - a check that policed every
number in a stylesheet would be refused within a week, which is the same as not
having one.

Usage: geometry-scale.py <radius,...> <border,...> <space-unit> <file> [file...]
"""

import re
import sys

# property name -> which part of the scale its lengths must come from.
#
# The CSS and rasi spellings sit beside the Lua ones because the three files
# describe the same four ideas in three syntaxes, and splitting the table by
# format would hide that they are the same table.
PROPERTIES = {
    # Corner radius
    "border-radius": "radius",
    "rounding": "radius",
    "corner_radius": "radius",
    # Border and separator thickness
    "border": "border",
    "border-width": "border",
    "border-size": "border",
    "border_size": "border",
    "frame_width": "border",
    "separator_height": "border",
    # Space, inside and out
    "padding": "space",
    "padding-top": "space",
    "padding-right": "space",
    "padding-bottom": "space",
    "padding-left": "space",
    "margin": "space",
    "margin-top": "space",
    "margin-right": "space",
    "margin-bottom": "space",
    "margin-left": "space",
    "spacing": "space",
    "gaps_in": "space",
    "gaps_out": "space",
    "min-width": "space",
    "min-height": "space",
}

# `border-left: 0px` and friends: a side-specific border still has to be a
# border width. Listed by rule rather than by name so the table stays short.
for side in ("top", "right", "bottom", "left"):
    PROPERTIES["border-" + side] = "border"

# `name: value;` in CSS and rasi; `name = value,` in hyprland's Lua.
DECLARATION = re.compile(
    r"(?P<name>[a-z_-]+)\s*(?::(?P<css>[^;{}]*);|=\s*(?P<lua>-?[0-9.]+)\s*,)",
    re.IGNORECASE,
)

# A length: a bare number with an optional px suffix. Anything else in the
# value - `solid`, `@border`, `0.5`, a colour - is not a length and is skipped.
LENGTH = re.compile(r"^(?P<value>\d+)(?:px)?$")


def strip_comments(text):
    """Blank out comments so a number inside one is not read as a declaration.

    Replaced with spaces rather than removed so that reported line numbers stay
    true to the file on disk.
    """
    def blank(match):
        return re.sub(r"\S", " ", match.group(0))

    text = re.sub(r"/\*.*?\*/", blank, text, flags=re.DOTALL)
    text = re.sub(r"^\s*--.*$", blank, text, flags=re.MULTILINE)
    return text


def lengths(value):
    """The lengths in a property value, in order."""
    for token in value.replace(",", " ").split():
        match = LENGTH.match(token)
        if match:
            yield int(match.group("value"))


def check(path, scale):
    text = strip_comments(open(path).read())
    failures = []

    for match in DECLARATION.finditer(text):
        part = PROPERTIES.get(match.group("name").lower())
        if part is None:
            continue

        value = match.group("css") if match.group("css") is not None else match.group("lua")
        line = text.count("\n", 0, match.start()) + 1

        for length in lengths(value):
            if length == 0:
                continue
            if part == "space":
                if length % scale["space"] == 0:
                    continue
                why = "not a multiple of %d" % scale["space"]
            else:
                if length in scale[part]:
                    continue
                why = "not one of %s" % ", ".join(str(v) for v in sorted(scale[part]))
            failures.append((line, match.group("name"), value.strip(), length, why))

    return failures


def main(argv):
    scale = {
        "radius": {int(v) for v in argv[1].split(",")},
        "border": {int(v) for v in argv[2].split(",")},
        "space": int(argv[3]),
    }

    failures = [(path, failure) for path in argv[4:] for failure in check(path, scale)]
    if not failures:
        return 0

    print("Lengths that are not on the geometry scale:\n", file=sys.stderr)
    for path, (line, name, value, length, why) in failures:
        print("  %s:%d\n    %s: %s\n    -> %s is %s\n" % (path, line, name, value, length, why),
              file=sys.stderr)
    print(
        "The scale is lib/geometry.nix. Move the value onto it, or - if the\n"
        "scale is what is wrong - change the scale, which is the point of it\n"
        "being in one file.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
