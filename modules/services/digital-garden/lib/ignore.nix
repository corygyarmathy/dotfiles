# Which vault paths the garden never looks at, defined ONCE.
#
# The rule: a path is ignored when any component below the vault root begins
# with a dot - .obsidian/, .git/, .sync.lock, .trash/, and a checkout nested
# under something like .claude/worktrees/. Components ABOVE the root never
# count, which is the half that used to go wrong: an inotifywait exclusion of
# '/\.' matched the vault's own ancestors, so a vault or stylesheet sitting
# under .claude/worktrees/ had every event excluded and the preview's watch
# loop silently stopped.
#
# Four consumers need this rule and each speaks a different regex dialect, so
# this file hands each one the dialect it needs from a single fragment rather
# than letting each spell its own:
#
# - publish-filter.py, which decides what is read (and so what can publish)
# - the build's stat-only stamp walk, which decides whether to run at all
# - the service's watcher and the preview's watcher, which decide when to
#   rebuild or re-render
#
# Every dialect is relative to the vault root: the shell consumers run from
# inside the vault and name it as `.`, so no path ever has to be escaped into a
# regex. checks/digital-garden-ignore.nix runs all three dialects against one
# vault and asserts they agree.
let
  # ERE over a vault-relative path: optional leading directories, then a
  # component that starts with a dot.
  dotted = "(.*/)?\\.";
in
{
  # publish-filter.py's fourth argument, applied with re.match to each path
  # relative to the vault, e.g. "notes/.trash/old.md".
  relative = "^${dotted}";

  # `find . -regextype posix-extended -regex <this> -prune`, run from the vault
  # root. find's -regex must match the WHOLE path, hence the trailing .*, and
  # find names every path from the start point, hence the leading ./.
  find = "\\./${dotted}.*";

  # `inotifywait --exclude <this> ... .`, run from the vault root. inotifywait
  # searches rather than matches, so it is anchored explicitly; paths outside
  # the vault (the preview also watches the stylesheet's directory) start
  # with / and are never excluded by it.
  inotify = "^\\./${dotted}";
}
