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

# --- the revision frontier (#247) --------------------------------------
#
# The revision loop (#196) is this runner's second entry point, and its
# frontier is checked before the ticket queue below: a human waiting on a
# revision is ahead of a backlog ticket, and the frontier rides the same
# poll rather than carrying a timer of its own - a second timer would
# need its own mutual exclusion against concurrency-of-one (ADR 0004 §8),
# which a check inside this poll gets for free. No webhook either: the
# poll already exists (ADR 0004 §3).
#
# The frontier is the open pull requests this runner opened - the
# hand-off label is only ever applied by this pipeline, and `--author`
# asks for the App's own besides - that carry at least one unacknowledged
# `/revise` comment from an account other than the agent's (ADR 0006's
# author filter). Only pull requests on this runner's own branches are
# considered: the branch prefix is what the original run cut and what no
# other workflow here creates, and the slug is validated against the same
# regex the ticket lane builds it with. Open only, oldest first, and the
# body is deliberately not in the field list.
#
# The `/revise` comment is the whole of the trigger, and it is checked
# per candidate, before anything is claimed, for the same reason the
# ticket lane filters before it claims: a pull request whose only
# comments are the agent's own must start no session, and a pull request
# whose rounds are spent must not be claimed to be stuck. The text after
# `/revise`, when there is any, is the instruction the round consumes; a
# bare `/revise` falls back to the human's review comments, and a request
# with nothing behind it starts no session either.
log "polling $repo for open hand-off-labelled pull requests"

revise_candidates="$(
	gh pr list \
		--repo "$repo" \
		--label "$handoff_label" \
		--author "$bot_login" \
		--state open \
		--search "sort:created-asc" \
		--limit 100 \
		--json number,title,headRefName |
		jq -c --arg prefix "$branch_prefix" '
      [ .[] | select(.headRefName | startswith($prefix)) ]
      | sort_by(.number)
    '
)"

revise_total="$(jq 'length' <<<"$revise_candidates")"
log "$revise_total hand-off-labelled pull request(s)"

# The per-candidate state the stuck path reads. The revision lane's
# hand-back reaches the pull request itself, not the ticket behind it.
tracker_kind="pr"
number=""
title=""
branch=""
pr_url=""
attempt=1
branch_created=0
pushed=0

# The budget's stuck path, reached before anything is claimed: a pull
# request whose rounds are already spent gets the same
# three writes every hand-back makes - comment, relabel, notification -
# and the run ends red, because a human owes it a decision. Relabel
# before comment, like the dead-run guard: a relabel that fails dies
# before anything is written, so the next poll retries both together
# rather than posting the comment a second time.
#
# The run-ends-red part is the run's whole shape, not just this pull
# request's: one poll handles one pull request, so a spent budget
# blocks revisable ones - and the ticket queue - behind it for one
# poll. Fine at concurrency 1, which is all this runner has; revisit if
# that ever changes. The comment's first line is anchored on `AFK agent:
# revision`, like the round comments and the hand-back: it is the last
# word the runner leaves here, so it is what the frontier reads the
# `/revise` request's acknowledgement from, and the queue behind it
# moves again on the next poll.
revise_stuck_budget() {
	local body="$run_dir/stuck-revise.md"

	{
		printf '%s\n' "AFK agent: revision budget spent."
		printf '%s\n' ""
		printf '%s\n' "The AFK agent is handing this pull request back without running another revision round."
		printf '%s\n' ""
		printf '%s\n' \
			"This pull request has had $max_revision_rounds revision round(s), and further rounds do not run. Each round is a session, a gate, a push and a CI watch; a disagreement between a reviewer and the model is otherwise unbounded spend."
		printf '%s\n' ""
		printf '%s\n' "The pull request is relabelled \`$stuck_label\`. Address the review comments by hand, or close the pull request: writing another \`/revise\` comment will not start another round."
	} >"$body"

	if ! gh pr edit "$number" --repo "$repo" \
		--remove-label "$handoff_label" --add-label "$stuck_label"; then
		die "#$number: could not relabel to $stuck_label; refusing to leave it in the revision queue"
	fi

	post_tracker_comment pr "$body"

	notify_stuck \
		"the revision budget is spent on this pull request; further rounds do not run" \
		"$pr_url is open and unfinished"
	exit 1
}

# The comments, collected per candidate BEFORE the claim - the same two
# calls the trigger has always needed: `pr view` for the review summaries
# and the issue comments, and the REST endpoint for the inline review
# comments, which `pr view` does not carry. The body is not asked for,
# and since #202 the advisory findings do not need it: they arrive as a
# comment posted by the agent's own account, so the author filter below
# drops them exactly as it drops the round comments - not reading the
# body remains a property of the query, not of the code's discipline.
collect_comments() {
	local n=$1 pr_json inline

	pr_json="$(gh pr view "$n" --repo "$repo" --json reviews,comments)"

	inline="$(
		gh api "repos/$repo/pulls/$n/comments" 2>/dev/null || printf '[]'
	)"
	[ -n "$inline" ] || inline='[]'

	# `-r` with the pull request document as the program's input - the
	# inline comments ride in beside it as `--argjson`. `-n` here would
	# be exactly the bug it is in any other filter: the program would
	# read `null` instead of the document and answer with only the
	# inline comments, and the review summaries would vanish silently.
	jq -r --arg bot "$bot_login" --argjson inline "$inline" '
      ( ([.reviews[]?
           | { author: .author.login,
               body: (.body // ""),
               at: (.submittedAt // ""),
               where: "review summary" }]
         + [.comments[]?
             | { author: .author.login,
                 body: (.body // ""),
                 at: (.createdAt // ""),
                 where: "comment" } ])
       + [$inline[]?
           | { author: (.user.login // ""),
               body: (.body // ""),
               at: (.created_at // ""),
               where: ("inline review comment on " + (.path // "an unnamed file")) } ]
      ) as $all
      | [$all[] | select(.author == $bot)] as $mine
      | [$all[] | select(.author != $bot)] as $human
      # Anchored: only the comments this loop posts as its own first word
      # count - the round comments, the hand-back and the budget comment,
      # which all start `AFK agent: revision` - not prose that mentions a
      # revision somewhere in it. The watermark is what an unacknowledged
      # `/revise` is measured against, and what keeps the comments of the
      # round before it from being re-fed as an instruction.
      | ([ $mine[] | select(.body | test("^AFK agent: revision")) | .at ] | max // "") as $since
      | [$human[] | select(.at > $since)] | sort_by(.at) as $outstanding
      | [$outstanding[] | select(.body | test("^/revise($|[[:space:]])"))] as $commands
      | ($commands | last // null) as $trigger
      | (if $trigger == null then ""
         else $trigger.body | sub("^/revise"; "") | sub("^[[:space:]]+"; "")
         end) as $instruction
      | { rounds: [$mine[] | select(.body | test("^AFK agent: revision round"))] | length,
          revise: (if $trigger == null then null
                   else { author: $trigger.author, instruction: $instruction }
                   end),
          payload: (if $instruction == ""
                    then ([$outstanding[]
                            | select(.body | test("^/revise($|[[:space:]])") | not)
                            | "### \(.author) - \(.where)\n\n\(.body)"]
                          | join("\n\n---\n\n"))
                    else "### \($trigger.author) - /revise instruction\n\n" + $instruction
                    end) }
    ' <<<"$pr_json"
}

revise_pick=""
revise_rounds=""
revise_author=""
index=0
while [ "$index" -lt "$revise_total" ]; do
	revise_candidate="$(jq -c ".[$index]" <<<"$revise_candidates")"
	index=$((index + 1))

	number="$(jq -r '.number' <<<"$revise_candidate")"
	title="$(jq -r '.title' <<<"$revise_candidate")"
	branch="$(jq -r '.headRefName' <<<"$revise_candidate")"
	pr_url="https://github.com/$repo/pull/$number"
	slug="${branch#"$branch_prefix"}"

	# The branch name is a pull request's head ref, not this runner's
	# own construction, so it is validated rather than trusted - and the
	# worktree's name, which the in-flight guard parses, is built from
	# it. Anything else is not a branch this pipeline opened.
	if ! [[ "$slug" =~ ^[0-9]+(-[a-z0-9]+)*$ ]]; then
		log "skipping #$number: '$branch' does not name a branch this runner cut, so it is not revised by this pipeline"
		continue
	fi

	revise_comments="$(collect_comments "$number")"

	if [ "$(jq -r '.revise == null' <<<"$revise_comments")" = true ]; then
		log "#$number: no /revise comment from accounts other than the agent's own; starting no session"
		continue
	fi

	if [ "$(jq -r '.rounds' <<<"$revise_comments")" -ge @MAX_REVISION_ROUNDS@ ]; then
		log "#$number: $max_revision_rounds revision round(s) already recorded; the budget is spent"
		revise_stuck_budget
	fi

	if [ -z "$(jq -r '.payload' <<<"$revise_comments")" ]; then
		log "#$number: the /revise comment carries no instruction and no review comment waits behind it; starting no session"
		continue
	fi

	revise_pick="$revise_candidate"
	revise_rounds="$(jq -r '.rounds' <<<"$revise_comments")"
	revise_author="$(jq -r '.revise.author' <<<"$revise_comments")"
	# The round's review input, written where it is picked: the `/revise`
	# comment's own text when it carries one, the review comments behind it
	# when it does not. The revision flow reads it back beside its prompt.
	jq -r '.payload' <<<"$revise_comments" >"$run_dir/revision-comments.md"
	break
done

if [ -z "$revise_pick" ]; then
	# Nothing waits on a revision, so the ticket queue below runs as
	# normal and the tracker surfaces the stuck path writes to are the
	# issue's again.
	tracker_kind="issue"
	log "nothing to revise this poll"
else
	# A human is waiting on this revision, and this poll is its runner:
	# the ticket claim below is skipped whole, and every issue-lane
	# stage reads `$flow` and steps aside until the revision flow at the
	# end of the script takes over from the claim onward.
	flow=revise
	log "#$number: the /revise comment is ahead of the ticket queue this poll"
fi

# --- poll -------------------------------------------------------------
#
# The ticket queue, and only when the revision frontier came back
# empty: a poll whose revision lane took it never reaches this claim.
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
if [ "$flow" = issue ]; then
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
		# The revision frontier above already had its say this poll, so an
		# empty queue is a quiet end to the run: nothing to claim, nothing
		# to revise, nothing to notify about.
		log "nothing to claim from '$label' this poll"
		exit 0
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
fi

# --- isolate ----------------------------------------------------------
#
