# shellcheck shell=bash
log() { echo "afk-agent: $*"; }
die() {
	echo "afk-agent: $*" >&2
	exit 1
}

# Turn a session title back into a session id, or print nothing.
#
# Written once because both stages need it and the pipeline is not
# trivial. `|| true` on the end is load-bearing rather than tidy, for the
# reason the review stage's own greps carry one: this is only ever
# called inside a
# command substitution, and under `set -euo pipefail` an `opencode` that
# fails or a `jq` that finds nothing would abort the runner right there -
# before either caller's own `die` could say which session it was looking
# for and why that matters. An empty answer has to travel back as an
# empty answer.
session_id_for() {
	(
		cd "$1" &&
			opencode session list -n @SESSION_LIST_DEPTH@ --format json |
			jq -r --arg t "$2" 'map(select(.title == $t)) | .[0].id // empty'
	) 2>/dev/null || true
}
