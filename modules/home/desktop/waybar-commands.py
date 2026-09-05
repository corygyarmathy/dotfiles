"""Assert that every command waybar's config can run actually exists.

Waybar parses config.jsonc happily whether or not the binaries it names are
installed, so a package dropped from the closure or a script renamed shows up
only as a click that does nothing - which is worse than no click at all,
because the bar documents an interaction grammar it then fails to honour. This
turns that into a build failure. See waybar.nix for why it runs at build time
rather than as a flake check.

Scope, deliberately narrow: the *head* of each command line, and nothing else.
Shell one-liners with pipes and $(...) are already in the config, and a check
that grew a shell parser to follow them would be a second, worse shell. The
head alone caught every dead action this was written for except two, and those
two hid their missing binary inside a $(...) - they were removed rather than
parsed for.

Usage: waybar-commands.py <config.jsonc> <bin-dir:bin-dir:...>
"""

import os
import sys

import json5


def is_command_key(key):
    """Is this a key whose value waybar hands to a shell?

    `actions` is deliberately not one of them. That object maps an event to a
    module-*internal* action name - clock's "mode", "shift_up" - which is not a
    command and must not be looked for on PATH.
    """
    return key in ("exec", "exec-if", "on-update") or key.startswith(("on-click", "on-scroll"))


def commands(node, path=()):
    """Yield (where in the config, command line) for everything waybar runs."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "actions":
                continue
            here = path + (key,)
            if is_command_key(key) and isinstance(value, str):
                yield ".".join(here), value
            else:
                yield from commands(value, here)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from commands(value, path + ("[%d]" % index,))


def head(command):
    """The binary a command line invokes: its first whitespace-separated word."""
    words = command.split()
    return words[0] if words else ""


def resolve(name, bindirs):
    return any(os.path.exists(os.path.join(d, name)) for d in bindirs)


def main(argv):
    config_path, search_path = argv[1], argv[2]
    bindirs = [d for d in search_path.split(":") if d]

    with open(config_path) as handle:
        config = json5.load(handle)

    failures = []
    for where, command in commands(config):
        name = head(command)
        if not name:
            failures.append((where, command, "the command is empty"))
        elif "/" in name or "=" in name:
            # Not a limitation worth lifting: a path or an inline assignment in
            # the bar's config is a shell-out that has outgrown a config file
            # and belongs in a script the closure can carry.
            failures.append((where, command, "%s: not a bare command name" % name))
        elif not resolve(name, bindirs):
            failures.append((where, command, "%s: not found" % name))

    if not failures:
        return 0

    print("%s names commands that are not installed:\n" % config_path, file=sys.stderr)
    for where, command, why in failures:
        print("  %s\n    %s\n    -> %s\n" % (where, command, why), file=sys.stderr)
    print(
        "Add the package that provides it to the closure, or remove the action.\n"
        "A declared click that runs nothing is worse than no click.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
