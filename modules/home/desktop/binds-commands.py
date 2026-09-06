"""Assert that every command binds.lua hands to a shell actually exists.

Item 1 of docs/plans/desktop-design.md checked waybar's config and noted that
the same question applies to binds.lua, which also names binaries -
"extending it is cheap afterwards". This is that extension, taken when items
8-15 added about a dozen commands to the file and made the keybind sheet
worth gating: a bind that runs a binary the closure does not carry is the
same dead-interaction defect the bar's check exists to stop.

Scope, deliberately narrow, like the waybar check: the *head* of every
exec_cmd("...") string, resolved against the same two closures the session
provides on PATH. A dispatch call (hl.dsp.*) is not a command and is not
looked for; neither is the inside of a `$(...)` in a non-exec_cmd string,
because there are none in this file and the waybar check's reasoning applies
unchanged.

Usage: binds-commands.py <binds.lua> <bin-dir:bin-dir:...>
"""

import os
import re
import sys

# exec_cmd("...") - the one way this file asks for a shell. The capture
# tolerates an escaped quote inside the string, the way the Lua does.
EXEC_CMD = re.compile(r'exec_cmd\(\s*"((?:[^"\\]|\\.)*)"')


def head(command):
    words = command.split()
    return words[0] if words else ""


def main(argv):
    binds_path, search_path = argv[1], argv[2]
    bindirs = [d for d in search_path.split(":") if d]

    with open(binds_path) as handle:
        text = handle.read()

    failures = []
    for command in EXEC_CMD.findall(text):
        name = head(command)
        if not name:
            failures.append((command, "the command is empty"))
        elif not any(os.path.exists(os.path.join(d, name)) for d in bindirs):
            failures.append((command, "%s: not found" % name))

    if not failures:
        return 0

    print("%s names commands that are not installed:\n" % binds_path, file=sys.stderr)
    for command, why in failures:
        print("    %s\n    -> %s\n" % (command, why), file=sys.stderr)
    print(
        "Add the package that provides it to the closure, or change the bind.\n"
        "A bind that runs nothing is the bar's dead click wearing a keyboard.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
