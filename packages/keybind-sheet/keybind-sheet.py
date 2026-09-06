#!/usr/bin/env python3
"""Render binds.lua as the keybind sheet rofi-menu presents.

Item 11 of docs/plans/desktop-design.md. binds.lua defines around sixty
bindings across labelled sections, and the only way to see them used to be
opening the file. This parses the deployed copy and renders every hl.bind(...)
call, grouped by the section comments the file already has.

The parse is deliberately narrow - it understands this file's one style, not
Lua. It is written by one person in one style and the form is stable; if it
ever stops parsing, the failure is a sheet that does not open, not a system
failure. The build also runs this over the checked-in binds.lua (see
hyprland.nix) so the sheet cannot silently stop opening at runtime.

Usage: keybind-sheet.py [binds.lua]   (defaults to ~/.config/hypr/binds.lua)
Prints the sheet - section headers and one entry per line - for rofi-menu.
"""

import os
import re
import sys

# A token in a key expression: a string literal, or a bare word (a variable
# or a name). Literals carry the separators, so they are concatenated raw.
TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*')

# Section headers are "----"-fenced "-- Title" lines - the file's convention
# since it first existed - so a title is only a title when a fence precedes
# it. A prose comment never does, which is what keeps multi-line explanation
# out of the sheet. A fence is "--" plus dashes; a title line is a single
# short "-- Title".
FENCE = re.compile(r"^--[\s-]+$")
HEADER = re.compile(r"^--\s+[A-Z]")
NOT_HEADER = re.compile(r"https?://|[.:/]$")


def render_key(expr):
    """Expand a bind's key expression the way the file uses it.

    `mod` is the SUPER variable the file defines; the workspace-loop binds
    concatenate a `key` variable that iterates 1-10. Everything else is a
    literal, or a name this parser does not understand and marks as such.
    """
    out = ""
    for token in TOKEN.findall(expr):
        if token.startswith('"'):
            out += token[1:-1]
        elif token == "mod":
            out += "SUPER"
        elif token == "key":
            out += "1-10"
        else:
            out += "<%s>" % token
    return out.strip()


def describe(action):
    """A label for the bind's action, from the action expression.

    An exec_cmd string is the command itself; a dispatcher call is its method
    name (window.close, focus); anything else is shown as written.
    """
    match = re.search(r'exec_cmd\("((?:[^"\\]|\\.)*)"\)', action)
    if match:
        return match.group(1)
    match = re.search(r"hl\.dsp\.([A-Za-z0-9_.]+)\(", action)
    if match:
        return match.group(1)
    return action


def parse(path):
    """Yield (section, key, action) for every bind, in file order."""
    section = "Keybinds"
    in_submap = False
    prev_was_fence = False
    buf = ""
    depth = 0

    with open(path) as handle:
        for raw in handle:
            line = raw.rstrip("\n").strip()

            if line.startswith("--"):
                if FENCE.match(line):
                    prev_was_fence = True
                else:
                    title = line[2:].strip()
                    if (
                        prev_was_fence
                        and HEADER.match(line)
                        and len(title) <= 45
                        and not NOT_HEADER.search(line)
                        and title
                    ):
                        section = title
                    prev_was_fence = False
                continue
            prev_was_fence = False

            if "define_submap" in line:
                in_submap = True
                continue
            if in_submap:
                if line == "end)":
                    in_submap = False
                continue

            if "hl.bind(" in line:
                if buf == "":
                    buf = line
                    depth = line.count("(") - line.count(")")
                else:
                    buf += " " + line
                    depth += line.count("(") - line.count(")")
            elif buf != "":
                # A continuation line of a multi-line bind - an argument line
                # does not itself contain "hl.bind(".
                buf += " " + line
                depth += line.count("(") - line.count(")")
            else:
                continue

            if depth <= 0:
                args = buf[len("hl.bind(") :].rstrip()
                if args.endswith(")"):
                    args = args[:-1]
                key_expr, _, rest = args.partition(",")
                yield section, render_key(key_expr), describe(rest)
                buf = ""
                depth = 0


def main(argv):
    path = argv[1] if len(argv) > 1 else os.path.expanduser("~/.config/hypr/binds.lua")
    try:
        rows = list(parse(path))
    except OSError as exc:
        print("keybind-sheet: %s" % exc, file=sys.stderr)
        return 1

    current = None
    for section, key, action in rows:
        if section != current:
            current = section
            print("── %s ──" % section)
        print("%s  %s" % (key.ljust(18), action))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
