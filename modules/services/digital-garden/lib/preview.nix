# Local preview for the digital garden: `nix run .#garden-preview`.
#
# Why this exists. Every visual change to this site used to be a round trip
# through PR -> CI gate -> merge -> promote `deploy` -> host auto-upgrade ->
# wait for the build timer, because there was no way to see a rendered page
# without deploying one. That loop is minutes long and it is the real reason
# customising the garden felt expensive; the Quartz build itself is ~3 seconds.
#
# So this runs the SAME renderer and the SAME Caddy config as the service (see
# lib/site.nix), against the real vault on this machine, and re-renders on save. A
# preview that diverged from production would be worse than none at all: it
# would let you tune CSS against a page the server will never emit.
#
# It reads the vault, and writes only to a temp directory and a dates cache.
# The publish boundary is the filter, exactly as in production — an unpublished
# note is not copied, so it is not rendered and not served here either.
{
  pkgs,
  lib,
  site,
  renderer,
  filter,
  defaultStyleSheet,
  defaultVault ? "$HOME/git/personal-notes",
}:
pkgs.writeShellApplication {
  name = "garden-preview";
  runtimeInputs = [
    (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
    renderer
    pkgs.caddy
    pkgs.inotify-tools
    pkgs.coreutils
  ];
  text = ''
    vault=''${GARDEN_VAULT:-${defaultVault}}
    port=8087
    once=false
    css=

    while [ $# -gt 0 ]; do
      case $1 in
        --vault) vault=$2; shift 2 ;;
        --css) css=$2; shift 2 ;;
        --port) port=$2; shift 2 ;;
        --once) once=true; shift ;;
        -h|--help)
          cat <<'USAGE'
    garden-preview [options]

      --vault PATH   Obsidian vault to publish from
                     (default: $GARDEN_VAULT, else ${defaultVault})
      --css PATH     stylesheet to render with. Defaults to the working-tree
                     copy if you are sitting in the dotfiles repo, so that
                     editing it re-renders without a Nix evaluation.
      --port N       port to serve on (default 8087)
      --once         render once and exit; do not serve or watch

    Renders the published subset of the vault exactly as the server does and
    serves it locally, re-rendering whenever the vault or the stylesheet
    changes.
    USAGE
          exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
      esac
    done

    # Prefer the stylesheet in the working tree when there is one, because
    # that is the file you are about to edit. The store copy baked into the
    # renderer is only reachable through a fresh evaluation of the host, which
    # is the loop this command exists to avoid.
    if [ -z "$css" ]; then
      if [ -f hosts/homelab01/digital-garden.scss ]; then
        css=hosts/homelab01/digital-garden.scss
      else
        css=${defaultStyleSheet}
        echo "note: using the stylesheet baked into the renderer." >&2
        echo "      run from the dotfiles repo root, or pass --css, to edit it live." >&2
      fi
    fi

    if [ ! -d "$vault" ]; then
      echo "no such vault: $vault" >&2
      exit 1
    fi
    vault=$(realpath "$vault")
    css=$(realpath "$css")

    state=$(mktemp -d --tmpdir garden-preview.XXXXXX)
    # The ledger is the one piece of state worth keeping between runs: it is
    # what gives each note a stable `published:` date. A throwaway ledger would
    # date every note today, every time, which is a difference from production
    # you would see on the page.
    cache=''${XDG_CACHE_HOME:-$HOME/.cache}/garden-preview
    mkdir -p "$cache"

    cleanup() {
      if [ -n "''${caddy_pid:-}" ]; then
        kill "$caddy_pid" 2>/dev/null || true
      fi
      rm -rf "$state"
    }
    trap cleanup EXIT

    render() {
      local started
      started=$(date +%s%N)
      # Same filter, same arguments, same boundary as the service.
      python3 ${filter} "$vault" "$state/content" "$cache/dates.json" || return 1
      digital-garden-render "$state/content" "$state/public.new" "$css" \
        > "$state/render.log" 2>&1 || {
          echo "render failed:" >&2
          tail -30 "$state/render.log" >&2
          return 1
        }
      # Swapped rather than written in place, so a re-render never serves a
      # half-written tree to a browser that reloads at the wrong moment.
      rm -rf "$state/public.old"
      if [ -d "$state/public" ]; then
        mv "$state/public" "$state/public.old"
      fi
      mv "$state/public.new" "$state/public"
      rm -rf "$state/public.old"
      echo "rendered in $(( ($(date +%s%N) - started) / 1000000 ))ms"
    }

    render || exit 1
    if [ "$once" = true ]; then
      echo "output: $state/public"
      # --once is for checking that a render succeeds, so keep what it built.
      trap - EXIT
      exit 0
    fi

    cat > "$state/Caddyfile" <<CADDY
    {
      auto_https off
      admin off
    }
    :$port {
    ${site.caddyConfig "$state/public"}
    }
    CADDY

    caddy run --config "$state/Caddyfile" --adapter caddyfile \
      > "$state/caddy.log" 2>&1 &
    caddy_pid=$!

    echo
    echo "  garden-preview  http://localhost:$port"
    echo "  vault           $vault"
    echo "  stylesheet      $css"
    echo "  watching for changes — ctrl-c to stop"
    echo

    # Watch the stylesheet's DIRECTORY, not the stylesheet. Editors - and sed,
    # and Obsidian - save by writing a temporary file and renaming it over the
    # target, which replaces the inode. A watch on the file itself then follows
    # the old inode into oblivion and never fires again, so the first save
    # after startup would be the last one the preview ever noticed.
    #
    # Dotfiles are excluded to match the filter, which ignores
    # .obsidian/.git/.sync.lock. Without this, Obsidian's own churn in
    # .obsidian re-renders the site continuously.
    cssdir=$(dirname "$css")
    inotifywait -q -m -r -e modify,create,delete,move,close_write \
      --exclude '/\.' --format '%w%f' "$vault/" "$cssdir/" \
      | while read -r changed; do
        # The stylesheet's neighbours in hosts/ are watched only because they
        # share its directory. Changing them means changing Nix, which this
        # loop cannot pick up anyway, so re-rendering for them would only
        # suggest it had.
        case "$changed" in
          "$css" | "$vault"/*) ;;
          *) continue ;;
        esac
        # Drain the rest of the burst: a single save arrives as several events,
        # and rendering on the first one reads the file mid-write.
        while read -r -t 0.3 _; do :; done
        render || true
      done
  '';
}
