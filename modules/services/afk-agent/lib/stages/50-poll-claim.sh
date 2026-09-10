# shellcheck shell=bash
# systemd already makes two live runs impossible (see the module header),
# but it has nothing to say about a run that died: a unit killed by the
# runtime ceiling, or by the kill switch, leaves its worktree behind, and
# the next poll would otherwise claim a second ticket beside the wreckage
# of the first. Refusing to start was only ever the conservative half of
# that - it wedged the pipeline on its first casualty, and the wreckage
# stayed until a hand removed it. The stuck path (#175) owns the
# other half, and the decision it makes is tear-down, not resume: each
# leftover worktree is handed back to its ticket - comment, relabel,
# teardown - and the poll then carries on.
#
# Anything here that cannot be handed back cleanly stops the run: a
# directory whose name is not a slug, a tracker that will not answer, a
# relabel that will not land. A runner that quietly worked around a
# wreck it could not identify would be the louder failure.
mkdir -p "$worktrees"
for leftover in "$worktrees"/*; do
	[ -e "$leftover" ] || continue
	if [ ! -d "$leftover" ]; then
		die "a worktree path from an earlier run is still here ($leftover) but is not a directory; remove it by hand"
	fi
	hand_back_dead_run "$leftover"
done

# --- poll -------------------------------------------------------------
#
# Two filters, and they now guard against different people. The label is
# the runner's own claim (ADR 0006): it drops the label when it takes a
# ticket, so a ticket it already holds is not in this list at all. The
# assignee filter is what keeps it off a ticket a *human* has taken -
# reading assignees works perfectly well as an App, it is only writing
# one that GitHub refuses, so nothing about that half had to change.
#
# Unblocked has a trap in it worth naming: `blockedBy.totalCount` counts
# every dependency edge, closed ones included, so it is not the gate it
# looks like. The open ones have to be counted from the nodes.
#
# `sort:created-asc` is doing real work, and is not the same thing as the
# `sort_by` below. `gh issue list` returns newest first, so past the
# limit it is the *oldest* tickets that fall off the end - and this
# claims the oldest survivor, so without it the ticket at the front of
# the queue would become permanently unreachable at exactly the point a
# backlog got long enough to matter. The search decides which hundred
# come back; the `sort_by` decides the order among them, and is kept so
# the ordering holds whatever the API does.
log "polling $repo for unassigned, unblocked '$label' issues"

candidates="$(
	gh issue list \
		--repo "$repo" \
		--label "$label" \
		--state open \
		--search "sort:created-asc" \
		--limit 100 \
		--json number,title,body,assignees,blockedBy |
		jq -c '
        [ .[]
          | select((.assignees | length) == 0)
          | select([.blockedBy.nodes[]? | select(.state == "OPEN")] | length == 0)
        ] | sort_by(.number)
      '
)"

total="$(jq 'length' <<<"$candidates")"
log "$total eligible candidate(s)"

# --- re-check the denylist, then claim the first survivor -------------
#
# Oldest first, which is the only ordering the tracker offers that is
# stable across polls. A ticket rejected here is skipped rather than
# relabelled: a rejection that stopped the poll would let one ineligible
# ticket block every eligible one behind it, and the stuck path is not
# the answer either - a ticket refused here was never claimed, so there
# is nothing to hand back, and commenting on it every poll would be
# noise about a ticket nobody is working. It is triage that relabels.
first_denied() {
	local text=$1 path
	for path in "${denied[@]}"; do
		if printf '%s' "$text" | grep -qiF -- "$path"; then
			printf '%s' "$path"
			return 0
		fi
	done
	return 1
}

picked=""
index=0
while [ "$index" -lt "$total" ]; do
	candidate="$(jq -c ".[$index]" <<<"$candidates")"
	index=$((index + 1))

	scope="$(jq -r '.title + "\n" + (.body // "")' <<<"$candidate")"

	if denied_path="$(first_denied "$scope")"; then
		log "skipping #$(jq -r '.number' <<<"$candidate"): its scope names the denied path '$denied_path' (docs/agents/afk-eligibility.md rule 1)"
		continue
	fi

	picked="$candidate"
	break
done

# Everything past this point acts on a claimed ticket, and two things
# can now happen to it. They have different exits, and the difference is
# whether anything was tried:
#
# - It cannot be *started*. The clone, the fetch and the worktree are
#   infrastructure the ticket did not choose, so nothing is handed back:
#   the claim is undone and the next poll tries again. Leaving the
#   ticket carrying `$working_label` instead would strand it - invisible
#   to the frontier query, and with no worktree behind, invisible to
#   the guard too.
# - It was *tried* and cannot be carried to a hand-off. That is
#   `hand_back` (#175): a comment saying what was tried and why
#   it stopped, `$working_label` swapped for `$stuck_label`, and a
#   teardown - never a pull request opened, nothing left in flight.
unclaim_and_die() {
	if ! gh issue edit "$number" --repo "$repo" \
		--remove-label "$working_label" --add-label "$label"; then
		echo "afk-agent: #$number: could not undo the claim either; the ticket carries $working_label and is invisible to the frontier query" >&2
	fi
	die "$1"
}

if [ -z "$picked" ]; then
	# The revision loop (plan item 12, #196) is this runner's second entry
	# point: when the ticket queue is empty, the run falls through to it.
	# `flow` is what every stage between here and the hand-off reads, and
	# the revision flow itself lives at the end of the script (150), after
	# the functions it reuses - the gate, the verdict, the push, the CI
	# watch - are defined. Nothing past the claim below runs with an
	# empty `$picked`.
	flow=revise
	log "nothing to claim from '$label' this poll; the revision queue is next"
else
	number="$(jq -r '.number' <<<"$picked")"
	title="$(jq -r '.title' <<<"$picked")"

	# State the hand-back reads, initialised where the claim lands so that
	# every exit past this point knows what this run created. `attempt`
	# belongs to the implement loop and is read by nothing before it.
	attempt=1
	branch_created=0
	pushed=0
	pr_url=""

	log "claiming #$number: $title"
	gh issue edit "$number" --repo "$repo" \
		--remove-label "$label" --add-label "$working_label"
fi

# --- isolate ----------------------------------------------------------
#
