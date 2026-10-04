# The vault-path ignore rule in lib/ignore.nix, run through every tool that
# consumes it, against one vault.
#
# Four things decide which vault files exist as far as the garden is
# concerned: publish-filter.py (what is read), the build's stamp walk (whether
# to build at all), and the service's and the preview's inotify watchers (when
# to rebuild). They used to spell the rule four ways and disagree. This check
# gives all of them the same vault and asserts they see the same two files.
# The two watchers share one dialect and one set of inotifywait flags, so one
# watcher run covers both.
#
# The vault deliberately sits UNDER a dotted directory (.claude/worktrees/),
# because that is how the old '/\.' exclusion failed: it matched the vault's own
# ancestors and silenced every event. Inside the vault it holds each kind of
# path the rule exists for - .obsidian/, .git/, .sync.lock, a dotted folder
# deeper down, and a checkout nested under its own .claude/worktrees/ - each
# holding a note marked `publish: true`, so a dialect that let one through
# would show it rather than hide it.
#
# Not a VM: every consumer is a program run on a directory, and running the
# real find and the real inotifywait is closer to the truth than booting a
# machine to run them.
{ pkgs }:
let
  ignore = import ../modules/services/digital-garden/lib/ignore.nix;
  filter = import ../modules/services/digital-garden/lib/filter.nix { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in
pkgs.runCommand "check-digital-garden-ignore"
  {
    nativeBuildInputs = [
      python
      pkgs.findutils
      pkgs.inotify-tools
    ];
    inherit filter;
    ignoreRelative = ignore.relative;
    ignoreFind = ignore.find;
    ignoreInotify = ignore.inotify;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    root=$(mktemp -d)
    vault="$root/.claude/worktrees/wt/vault"
    note() {
      mkdir -p "$(dirname "$vault/$1")"
      printf -- '---\npublish: true\n---\n\n# %s\n' "$1" > "$vault/$1"
    }
    note top.md
    note notes/kept.md
    note .obsidian/workspace.md
    note .git/COMMIT.md
    note notes/.trash/old.md
    note sub/.claude/worktrees/co/notes/nested.md
    touch "$vault/.sync.lock"

    # What every consumer should see, by vault-relative path.
    expected=$(printf '%s\n' notes/kept.md top.md)

    # --- the filter ----------------------------------------------------------
    # The staged tree is flat, so compare by file name.
    work=$(mktemp -d)
    python3 "$filter/publish-filter.py" "$vault" "$work/content" \
      "$work/dates.json" "$ignoreRelative" > "$work/log" \
      || fail "filter exited non-zero: $(cat "$work/log")"
    staged=$(cd "$work/content" && find . -name '*.md' -printf '%f\n' | sort)
    [ "$staged" = "$(printf '%s\n' "$expected" | xargs -n1 basename | sort)" ] \
      || fail "filter staged:
    $staged
    expected the basenames of:
    $expected"

    # --- the stamp walk ------------------------------------------------------
    # The same find expression the build script runs, from the same place.
    walked=$(cd "$vault" && find . -regextype posix-extended -regex "$ignoreFind" \
      -prune -o -type f -printf '%P\n' | sort)
    [ "$walked" = "$expected" ] || fail "stamp walk saw:
    $walked
    expected:
    $expected"

    # --- the watchers --------------------------------------------------------
    # The same flags both watchers pass, from inside the vault, plus the
    # preview's second watch on a stylesheet directory that is itself under
    # the dotted ancestor - the exact shape the old exclusion silenced. Every
    # file is written, then a sentinel; events arrive in order, so once the
    # sentinel is reported every earlier event has been too.
    assets="$root/.claude/worktrees/wt/assets"
    mkdir -p "$assets"
    touch "$assets/main.css"
    events=$(mktemp)
    errors=$(mktemp)
    (cd "$vault" && exec inotifywait -m -r -e modify,create,delete,move,close_write \
      --exclude "$ignoreInotify" --format '%w%f' . "$assets/" > "$events" 2> "$errors") &
    watcher=$!
    wait_for() {
      for _ in $(seq 200); do
        grep -q "$1" "$2" && return 0
        sleep 0.05
      done
      fail "timed out waiting for '$1' in $2: $(cat "$2")"
    }
    wait_for "Watches established" "$errors"
    (cd "$vault" && find . -type f -exec sh -c 'echo edit >> "$1"' _ {} \;)
    echo edit >> "$assets/main.css"
    touch "$vault/sentinel"
    wait_for '^\./sentinel$' "$events"
    kill "$watcher"

    seen=$(grep -v -e '^\./sentinel$' -e "^$assets/" "$events" | sed 's|^\./||' | sort -u)
    [ "$seen" = "$expected" ] || fail "watcher reported:
    $seen
    expected:
    $expected
    raw events:
    $(cat "$events")"
    grep -q "^$assets/main.css$" "$events" \
      || fail "watcher missed the stylesheet under a dotted ancestor; raw events:
    $(cat "$events")"

    touch "$out"
  ''
