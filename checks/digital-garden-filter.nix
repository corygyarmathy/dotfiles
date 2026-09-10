# The shelf-collision refusal in publish-filter.py, invoked directly.
#
# The property cannot be asserted through the served site, because a merged
# shelf serves normally: a page built from two folders that slug to the same
# shelf is indistinguishable from a correct one, so nothing downstream can
# catch it. Asserting against the VM check's own vault would prove only that
# we did not write a collision into that fixture, while a vault that actually
# collides - the only one the check never sees - would merge folders
# unnoticed. So the filter is run here against a deliberately colliding vault,
# and its refusal is the assertion.
#
# The fixture is built inside this script and is entirely separate from the
# VM check's vault fixture in checks/digital-garden.nix, which it does not
# disturb: that check keeps exercising the ordinary render, and this one only
# adds the set's new test seam.
{ pkgs }:
let
  # The filter as ONE directory - the same assembly the service and the
  # preview run, not a copy assembled a second time here. See lib/filter.nix.
  filter = import ../modules/services/digital-garden/lib/filter.nix { inherit pkgs; };
  # pyyaml for the frontmatter pass, exactly as the service's build script
  # provides it.
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in
pkgs.runCommand "check-digital-garden-filter-shelf-collision"
  {
    nativeBuildInputs = [ python ];
    # A direct attribute rather than a nativeBuildInputs entry, so the store
    # path is an environment variable the script can name - the filter's
    # output is a directory of two files, not a bin/ to be found on PATH.
    inherit filter;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    run() { python3 "$filter/publish-filter.py" "$@"; }

    # --- a colliding vault is refused ---------------------------------------
    # Two DIFFERENT leaf names that slug to the same shelf (`Meetings` and
    # `_Meetings`, in two parents), so the refusal is proven against the slug
    # and not the name - which also covers the identical-name case,
    # `Work/Meetings` against `Home/Meetings`, the shape the real vault holds
    # three of.
    vault=$(mktemp -d)
    work=$(mktemp -d)
    staging="$work/content"
    ledger="$work/dates.json"
    mkdir -p "$vault/Work/Meetings" "$vault/Home/_Meetings"
    cat > "$vault/Work/Meetings/standup.md" <<'NOTE'
    ---
    publish: true
    ---

    # Standup
    NOTE
    cat > "$vault/Home/_Meetings/retro.md" <<'NOTE'
    ---
    publish: true
    ---

    # Retro
    NOTE

    set +e
    output=$(run "$vault" "$staging" "$ledger" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "colliding vault: expected exit 1, got $rc; output:
    $output"
    echo "$output" | grep -q "Work/Meetings" \
      || fail "colliding vault: refusal does not name Work/Meetings; output:
    $output"
    echo "$output" | grep -q "Home/_Meetings" \
      || fail "colliding vault: refusal does not name Home/_Meetings; output:
    $output"
    echo "$output" | grep -q "meetings" \
      || fail "colliding vault: refusal does not name the shared slug; output:
    $output"

    # Refusal means a stale site, not a half-written one: nothing is staged
    # and the ledger is untouched, so the served site stays exactly as it was.
    [ ! -e "$staging" ] || fail "colliding vault: staging tree was written anyway"
    [ ! -e "$ledger" ] || fail "colliding vault: ledger was written anyway"

    # --- a vault with no collision renders as it does today ------------------
    # Same two notes, one folder renamed so the shelves differ. Expected:
    # ordinary success, both notes staged, each keeping its own shelf - the
    # guard adds no behaviour to a vault without a collision.
    mv "$vault/Home/_Meetings" "$vault/Home/Notes"
    work=$(mktemp -d)
    staging="$work/content"
    ledger="$work/dates.json"
    output=$(run "$vault" "$staging" "$ledger") \
      || fail "clean vault: filter exited non-zero ($?); output:
    $output"
    echo "$output" | grep -q "published 2 notes" \
      || fail "clean vault: expected both notes published; output:
    $output"
    grep -q "^topic: meetings$" "$staging/standup.md" \
      || fail "clean vault: standup lost its shelf; staged file:
    $(cat "$staging/standup.md")"
    grep -q "^topic: notes$" "$staging/retro.md" \
      || fail "clean vault: retro lost its shelf; staged file:
    $(cat "$staging/retro.md")"

    touch "$out"
  ''
