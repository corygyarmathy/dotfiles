# checks/fmt-gate.nix
#
# Item 4 of #219: test the formatting gate against correctly and incorrectly
# formatted input. Until this existed, the only evidence the gate worked was a
# green run - which looks identical whether the gate would have caught a dirty
# PR or not.
#
# Not a VM: what is under test is the exit behaviour of the formatter wrapper
# and the treefmt.toml it consumes, not a running service. The Nix build
# sandbox has no nix daemon, so `nix fmt`'s resolution hop - evaluating this
# flake and execing the wrapper - is out of reach here; CI's lint job
# exercises it every run (`nix fmt -- --ci` on a real checkout). Everything
# from the wrapper onward is under test, by running the same `self.formatter`
# derivation the `nix fmt` hop would exec, against scratch git repos carrying
# this repo's treefmt.toml.
#
# The clean expectations are not stored in the repo: they are produced by the
# pinned formatters inside the check. Checked-in "correctly formatted" samples
# would drift from flake.lock the same way a PATH binary does - the failure
# mode ADR 0008 exists to close. The dirty samples are instead what every
# assertion pivots on: the gate must reject them, the write pass must change
# them, and the gate must then accept its own output.
{
  pkgs,
  self,
}:
let
  # The same wrapper `nix fmt` execs. x86_64-linux only, matching the checks
  # wiring in flake.nix.
  formatter = self.formatter.x86_64-linux;
in
pkgs.runCommand "check-fmt-gate" { nativeBuildInputs = [ pkgs.git ]; } ''
    set -eu

  fail() { echo "FAIL: fmt-gate: $*" >&2; exit 1; }
  assert_rc() { # assert_rc <0|ne0> <label> <cmd...>
    want=$1; label=$2; shift 2
    log="$PWD/last.log"
    set +e
    "$@" >"$log" 2>&1
    rc=$?
    set -e
    if [ "$want" = 0 ] && [ "$rc" -ne 0 ]; then
      echo "--- $label: exited $rc, expected 0" >&2
      cat "$log" >&2
      fail "$label exited $rc, expected 0"
    elif [ "$want" = ne0 ] && [ "$rc" = 0 ]; then
      fail "$label exited 0, expected failure"
    fi
  }

    # treefmt writes its cache outside the tree unless told otherwise; keep
    # everything sandbox-local. `orig` and the caches live outside the scratch
    # repos: anything inside one is walked and formatted.
    export HOME="$PWD/home"
    export XDG_CACHE_HOME="$PWD/cache"
    export XDG_CONFIG_HOME="$PWD/config"
    mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

    ############################################################
    # Scratch repo: this repo's treefmt.toml, dirty samples of
    # every file type the pipeline claims to cover, and a dirty
    # file the excludes claim to cover.
    ############################################################
    repo="$PWD/repo"
    orig="$PWD/orig"
    buildroot="$PWD"
    mkdir "$repo" "$orig"
    cp ${../treefmt.toml} "$repo/treefmt.toml"
    cd "$repo"
    git init -q
    git config user.email check@example.com
    git config user.name fmt-gate

    printf 'x=1\n\ndef  f( a, b ) :\n    return a+b\n' > dirty.py
    printf 'package main\n\nfunc main(){\nx:=1\n_ = x\n}\n' > dirty.go
    printf '{\n  a = 1;b = 2;\n}\n' > dirty.nix
    printf '#  Heading\n\n\nsome  text\n\n- a\n  - b\n' > dirty.md
    printf '#!/bin/sh\nif true; then\n  echo hi\nfi\n' > dirty.sh
    # secrets/*.yaml is excluded globally (sops payloads): the gate must ignore it.
    mkdir secrets
    printf '\tkey:  "value"\n\tlist:\n-\ta\n-\tb\n' > secrets/dirty.yaml

    for f in dirty.py dirty.go dirty.nix dirty.md dirty.sh secrets/dirty.yaml; do
      mkdir -p "$orig/$(dirname "$f")"
      cp "$f" "$orig/$f"
    done
    git add -A

    # A tree that is dirty under the pipeline must fail the gate - the whole
    # point of `--ci`. (--ci formats in place and then fails on the change,
    # which the next two assertions lean on.)
    assert_rc ne0 "gate on dirty tree" ${formatter}/bin/formatter --ci

    # Every dirty sample was changed, and the excluded file was not.
    for f in dirty.py dirty.go dirty.nix dirty.md dirty.sh; do
      cmp -s "$f" "$orig/$f" && fail "$f was not reformatted under --ci"
    done
    cmp -s secrets/dirty.yaml "$orig/secrets/dirty.yaml" \
      || fail "secrets/*.yaml was reformatted despite the exclude"

    # Write mode on the now-clean tree is a no-op that exits 0, and the gate
    # accepts its own output.
    assert_rc 0 "write mode on clean tree" ${formatter}/bin/formatter
    assert_rc 0 "gate on formatted tree" ${formatter}/bin/formatter --ci

    # Each file type re-dirtied on its own must fail the gate on its own: the
    # per-formatter half of item 4. (The tree was proven clean one assertion
    # ago, so each failure is attributable to the file just re-dirtied.)
    while IFS= read -r f; do
      cp "$orig/$f" "$f"
      assert_rc ne0 "gate on re-dirtied $f" ${formatter}/bin/formatter --ci
      ${formatter}/bin/formatter >/dev/null 2>&1 # clean up for the next iteration
    done <<'EOF'
  dirty.py
  dirty.go
  dirty.nix
  dirty.md
  dirty.sh
  EOF

    ############################################################
    # A formatter declared without its binary must be a hard
    # error, not a silent skip - that is what keeps the
    # runtimeInputs list in flake.nix honest against
    # treefmt.toml.
    ############################################################
  repo2="$buildroot/repo2"
  mkdir "$repo2"
  cp ${../treefmt.toml} "$repo2/treefmt.toml"
  # cp preserves the store path's read-only mode; the append below needs write.
  chmod u+w "$repo2/treefmt.toml"
    printf '\n[formatter.not-a-real-formatter]\ncommand = "not-a-real-formatter"\nincludes = ["*.txt"]\n' >> "$repo2/treefmt.toml"
    cd "$repo2"
    git init -q
    git add -A
    assert_rc ne0 "declared formatter without a binary" ${formatter}/bin/formatter

    touch "$out"
''
