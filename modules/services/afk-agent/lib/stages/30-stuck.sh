# shellcheck shell=bash
# --- the stuck path ----------------------------------------------------
#
# A claimed ticket that cannot be carried to a hand-off is handed back
# rather than dropped: the reason goes to this unit's journal AND to the
# ticket as a comment, `$working_label` becomes `$stuck_label` in one
# edit, and everything the run built that nothing points at is torn
# down. No pull request is ever opened here, and the next poll starts
# clean - which is what makes it safe for the success path to leave
# nothing behind either.
#
# The two halves split by the push because
# ADR 0007 moved the pull request in front of the review:
#
# - Before the push, ADR 0004 §6's "never a PR" holds in full, and so
#   does the plan's "no WIP branch left dangling for a run that never
#   pushed": the worktree and the local branch go, and nothing reaches
#   origin.
# - Past the push there is a pull request to reach. It is commented on
#   as well as the issue, and left open without the hand-off label -
#   which is the only signal, from outside, that nobody has finished
#   with it (ADR 0007 §2). It holds real work, so the branch stays on
#   origin and locally, and only the worktree goes.
#
# The order inside is load-bearing. The tracker writes come first
# because they are the part that outlives this process: a teardown that
# fails once is retried by the next poll's guard, but a comment that was
# never written is gone for good, and a ticket still carrying
# `$working_label` once its worktree is gone is stranded silently -
# invisible to the frontier query, missed by the guard, and known to
# nobody. The ntfy push comes after the tracker writes
# for the same reason - the phone's copy is a pointer at the durable
# half, not a substitute for it - and before the teardown, which is the
# slow part. `exit 1` at the end keeps the unit red: the hand-back is the
# designed outcome, and it is still a failure somebody has to act on.

# The tracker writes every hand-back shares, so the two stuck paths do
# not each restate them. Relabel is the durable half - it is what takes
# the ticket out of the frontier query - the comment is the explanation,
# and the closing paragraph names the decision a human now owes the
# ticket. A failed comment is non-fatal because the reason is already in
# this unit's journal; a failed relabel is the caller's call, because
# only the caller knows whether a ticket left carrying `$working_label`
# is about to be retried by the guard or stranded by a teardown.
#
# The revision lane (#196) hands back over the pull request rather than
# the issue, so the verbs read `$tracker_kind`: a pull request is not an
# issue to `gh issue edit`'s relabel, and the hand-back must reach the
# surface the reviewer is actually looking at.
stuck_closing() {
	if [ "$tracker_kind" = pr ]; then
		printf '%s\n' "The pull request is relabelled \`$stuck_label\`. It needs a human decision: address the review comments by hand, or re-apply \`$revise_label\` to spend another revision round (docs/agents/triage-labels.md)."
	else
		printf '%s\n' "The ticket is relabelled \`$stuck_label\`. It needs a human decision: reshape it and re-apply \`$label\`, or take it by hand (docs/agents/triage-labels.md)."
	fi
}

post_tracker_comment() {
	if [ "$tracker_kind" = pr ]; then
		if ! gh pr comment "$number" --repo "$repo" --body-file "$1"; then
			echo "afk-agent: #$number: the comment could not be posted; the reason above is in this unit's journal" >&2
		fi
	else
		if ! gh issue comment "$number" --repo "$repo" --body-file "$1"; then
			echo "afk-agent: #$number: the comment could not be posted; the reason above is in this unit's journal" >&2
		fi
	fi
}

relabel_stuck() {
	if [ "$tracker_kind" = pr ]; then
		gh pr edit "$number" --repo "$repo" \
			--remove-label "$working_label" --add-label "$stuck_label"
	else
		gh issue edit "$number" --repo "$repo" \
			--remove-label "$working_label" --add-label "$stuck_label"
	fi
}

hand_back() {
	local reason=$1
	local body="$run_dir/stuck.md"
	local rescued=0

	echo "afk-agent: #$number: $reason" >&2

	# The same rescue the dead-run guard does, for the same reason. A run
	# that exhausts its attempts can be holding real work: `attempt_verdict`
	# fails an attempt whose changes are still in the working tree, so
	# "three attempts and none passed" and "there is nothing here worth
	# keeping" are different statements and this used to conflate them.
	# Only where nothing was pushed - past the push the branch is kept
	# anyway and the pull request is what holds the work.
	if [ "$pushed" -eq 0 ] && rescue_uncommitted "$worktree" "$number"; then
		rescued=1
	fi

	{
		if [ "$tracker_kind" = pr ]; then
			printf '%s\n' "The AFK agent stopped work on this revision round and is handing it back."
		else
			printf '%s\n' "The AFK agent stopped work on this ticket and is handing it back, without opening a pull request."
		fi
		printf '%s\n' ""
		printf '%s\n' "Why it stopped:"
		printf '%s\n' ""
		printf '%s\n' "$reason"
		printf '%s\n' ""
		if [ "$tracker_kind" = pr ]; then
			# The revision lane's pull request predates this run and holds
			# work a reviewer has already read, so nothing here is torn down
			# and nothing is closed. What this run added - or did not - is
			# what the paragraph has to say.
			if [ "$pushed" -eq 1 ]; then
				printf '%s\n' \
					"The revision was pushed to \`$branch\`, but it did not reach a green CI run: $pr_url is open with the revision on it and unverified."
			elif [ "$rescued" -eq 1 ]; then
				printf '%s\n' \
					"The worktree is removed, but the work it held is committed onto \`$branch\` locally, **unpushed, in \`$checkout\` on the runner's host**: it has passed nothing - not the gate, not the path denylist, not CI - and it was never pushed, because the pre-push gate is the only thing that may authorise a push."
			else
				printf '%s\n' \
					"Nothing was pushed: $pr_url is open exactly as the reviewer left it, with the comments still unaddressed. The worktree is removed."
			fi
		elif [ "$pr_url" != "" ]; then
			printf '%s\n' \
				"The pull request ($pr_url) is left open without the \`@HANDOFF_LABEL@\` label: it holds the branch's work, and the label's absence is what says from outside that nobody has finished with it (ADR 0007 §2). The worktree is removed and the branch is left untouched."
		elif [ "$pushed" -eq 1 ]; then
			printf '%s\n' \
				"The worktree is removed. The branch \`$branch\` reached origin and is kept there - it holds the work the gate passed on, and a pull request can be opened from it by hand."
		elif [ "$rescued" -eq 1 ]; then
			printf '%s\n' \
				"The worktree is removed, but the branch \`$branch\` is kept **unpushed, in \`$checkout\` on the runner's host**: there was work left in the worktree, and it is committed onto that branch as a single \`WIP\` commit rather than deleted with the directory. That commit has passed nothing - not the gate, not the path denylist, not CI, and no review - and it was never pushed, because the pre-push gate is the only thing that may authorise a push. Read it as a starting point or delete the branch."
		elif [ "$branch_created" -eq 1 ]; then
			printf '%s\n' "The worktree and the branch \`$branch\` are removed. There was no work left in the worktree to keep."
		else
			printf '%s\n' "Nothing of this run was left behind."
		fi
		printf '%s\n' ""
		stuck_closing
	} >"$body"

	post_tracker_comment "$body"

	# The other half of reaching a run that failed past the push:
	# The pull request gets the same story the issue does, so a
	# reader who arrives at the pull request rather than the ticket is
	# not left guessing. A comment on a pull request is reportable and
	# removable; the hand-off label's absence is still what says this
	# pull request is not finished.
	#
	# The revision lane is already there: its hand-back comment above
	# went to the pull request, and posting the same body a second time
	# would be noise about a reviewer's only copy of the story.
	if [ "$tracker_kind" != pr ] && [ "$pr_url" != "" ]; then
		if ! gh pr comment "$pr_url" --repo "$repo" --body-file "$body"; then
			echo "afk-agent: #$number: the pull request comment could not be posted" >&2
		fi
	fi

	# One edit, like the claim, so the ticket is never briefly carrying
	# both labels or neither. A failure here is not fatal to what
	# follows - the teardown still runs - but the journal says the ticket
	# is stranded with its claim marker on, which is the loudness a
	# half-handed-back ticket deserves.
	if ! relabel_stuck; then
		echo "afk-agent: #$number: could not relabel to $stuck_label; the ticket still carries $working_label and is invisible to the frontier query" >&2
	fi

	# The notification. The tracker writes above are the
	# durable half of the hand-back; this is the half that reaches
	# somebody who is not looking at GitHub, at the lane's informational
	# level (priority low, silent) - a stuck pipeline stops work until a
	# human reads the ticket, but it should not wake them up to do it.
	notify_stuck "$reason" \
		"$(if [ "$pr_url" != "" ]; then printf '%s is open and unfinished' "$pr_url"; fi)"

	if [ "$pushed" -eq 0 ]; then
		# `$branch_created` says the branch is this run's to delete; the
		# rescue says there is now something on it that should outlive the
		# run. Both have to agree before it goes.
		if [ "$rescued" -eq 1 ]; then
			remove_worktree_and_branch "$worktree" "$branch" 0
		else
			remove_worktree_and_branch "$worktree" "$branch" "$branch_created"
		fi
	else
		# Pushed work stays: it is what the pull request is made of, and
		# the success path keeps its local branch for the same reason.
		remove_worktree_and_branch "$worktree" "$branch" 0
	fi
	exit 1
}

# What a dying run leaves in its worktree, committed onto its branch
# before anything is torn down.
#
# Tear-down rather than resume stands:
# The dead run's prompt, logs and attempt count
# did not survive it, and resuming unattended work nobody can vouch for
# is what ADR 0004 §6 exists to prevent. *Keeping* is not *resuming*.
# The ticket is still handed to a human; this only means what the run had
# written is still there when they go looking.
#
# It is committed and never pushed. `push_gate` is the only thing in this
# script allowed to authorise a push, and this work has not passed it -
# it has not passed anything, which is why the commit message says so in
# the first line rather than in a trailer somebody has to look for. The
# branch stays local, on the host, and the ticket comment says where.
#
# Guarded rather than fatal throughout, like every other step of a
# teardown: a rescue that fails must not stop the ticket being handed
# back. It answers 0 when a commit landed and 1 otherwise, and the
# callers use that for both what they say and whether they may delete
# the branch afterwards.
rescue_uncommitted() {
	local wt=$1 num=$2

	[ -d "$wt" ] || return 1

	# `--porcelain` covers modified, added, deleted and untracked alike,
	# which is what `git add -A` is about to stage. An empty answer means
	# there is nothing here worth a commit - the ordinary case, and not a
	# failure.
	if [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
		return 1
	fi

	if ! git -C "$wt" add -A 2>/dev/null; then
		echo "afk-agent: #$num: there is uncommitted work in $wt but it could not be staged; it is left in the worktree" >&2
		return 1
	fi

	if ! git -C "$wt" commit --no-verify -m "WIP: rescued from a run that died - this has passed no gate" -m "The AFK agent was working ticket #$num when its run ended without handing the ticket back - killed by the runtime ceiling, the memory ceiling, or the kill switch. This commit is whatever was in the worktree at that moment, committed so that it is not lost with the worktree." -m "It has passed nothing: not the local gate, not the path denylist, not CI, and no review. It was never pushed, because the pre-push gate is the only thing that may authorise a push and this did not go through it. Read it as a starting point or delete the branch." 2>/dev/null; then
		echo "afk-agent: #$num: there is uncommitted work in $wt but it could not be committed; it is left in the worktree" >&2
		return 1
	fi

	echo "afk-agent: #$num: committed what the dead run left in its worktree onto $branch_prefix$(basename "$wt"), unpushed"
	return 0
}

# The teardown both stuck paths share. Worktree first - a branch checked
# out in a living worktree cannot be deleted - then the local branch
# when the caller says so, which is only ever for a run that never
# pushed. Every step is guarded rather than fatal, because a teardown
# that half-fails must not stop the ticket being handed back; the next
# poll's guard retries whatever is left.
#
# --force on the worktree, where the success path's removal has none:
# a stuck run's tree is by definition not a tree anything vouched for,
# and a dirty one is exactly what a run killed mid-edit leaves.
remove_worktree_and_branch() {
	local wt=$1 branch_name=$2 delete_local=$3

	if [ -d "$wt" ]; then
		git -C "$checkout" worktree remove --force "$wt" ||
			echo "afk-agent: could not remove $wt; remove it by hand before the next poll" >&2
	fi

	if [ "$delete_local" -eq 1 ] &&
		git -C "$checkout" show-ref --verify --quiet "refs/heads/$branch_name"; then
		git -C "$checkout" branch -D "$branch_name" ||
			echo "afk-agent: could not delete the local branch $branch_name" >&2
	fi
}

# The other half of the stuck path, run by the in-flight guard below: a
# worktree on disk from a run that died before it could hand its ticket
# back. The ticket number is read out of the worktree's name, which is
# the slug the dead run built, so nothing has to have survived the run
# that died.
#
# Resuming unattended work nobody can vouch for is the shape ADR 0004 §6 exists
# to prevent. The comment says what is known, which is not much, and
# says it rather than guessing.
hand_back_dead_run() {
	local path=$1 name number branch pushed_branch open_prs ls_rc body rescued

	name="$(basename "$path")"
	number="${name%%-*}"
	branch="$branch_prefix$name"

	# The slug is validated below as digits first, so what is in front of
	# the first dash is the ticket number. A directory that does not
	# parse is not this runner's worktree, and tearing down something
	# unidentified is the one thing this path must not do.
	if ! [[ "$number" =~ ^[0-9]+$ ]]; then
		die "a worktree from an earlier run is still here ($path) but its name does not name a ticket; remove it by hand"
	fi

	# An open pull request for this branch means the run finished and only
	# its worktree survived - the ticket is done, not stuck, and
	# relabelling it under its own open pull request would be a lie. The
	# worktree is cleared, the branch stays (it is what the pull request
	# is from), and the ticket is not touched.
	#
	# One exception, and it is the revision lane's (#196): only a revision
	# run ever puts `$working_label` on a pull request - the ticket lane's
	# claim lives on the issue - so a pull request carrying it is a
	# revision run that died mid-round, with the human's trigger label
	# consumed by a run that never finished. The claim is undone the same
	# way `unclaim` does it on the issue lane: swap the labels back in one
	# edit, so the next poll can take the round again. The PR number comes
	# from the lookup, not from the worktree's name: the worktree is named
	# after the branch, which carries the original ticket's number, not
	# the pull request's.
	open_prs="$(gh pr list --repo "$repo" --head "$branch" --state open --json number,labels)" ||
		die "#$number: could not ask the tracker whether a pull request is open for $branch"

	if [ "$(jq 'length' <<<"$open_prs")" -gt 0 ]; then
		if jq -e --arg l "$working_label" 'any(.[].labels[]?; .name == $l)' \
			<<<"$open_prs" >/dev/null; then
			if ! gh pr edit "$(jq -r '.[0].number' <<<"$open_prs")" --repo "$repo" \
				--remove-label "$working_label" --add-label "$revise_label"; then
				die "#$number: a revision run died on the open pull request for $branch and its claim could not be undone; refusing to start a new ticket beside it"
			fi
			log "#$number: a revision run died on the open pull request for $branch; its claim was undone and the round will be retried"
		else
			log "#$number: a pull request is open for $branch, so the run finished and only its worktree survived; clearing it and moving on"
		fi
		remove_worktree_and_branch "$path" "$branch" 0
		return 0
	fi

	# A run killed between the push and the pull request leaves a pushed branch, and pushed work
	# is kept - it is what a pull request can be opened from, the same
	# rule the hand-back above follows past the push.
	pushed_branch=0
	if git -C "$checkout" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1; then
		pushed_branch=1
	else
		ls_rc=$?
		if [ "$ls_rc" -ne 2 ]; then
			die "#$number: could not ask origin whether $branch is there"
		fi
	fi

	# Whatever the dead run had written, committed onto its branch before
	# anything is removed. Ordered here rather than beside the teardown so
	# that the comment below can say what actually happened to it, and so
	# that a rescue is never skipped by the `$stuck_label` early-out - a
	# hand-back whose teardown failed last poll still has the work on disk.
	rescued=0
	if rescue_uncommitted "$path" "$number"; then
		rescued=1
	fi

	# The tracker writes first, for the reason hand_back gives - and are
	# skipped when the ticket already carries `$stuck_label`, which is
	# the shape a hand-back whose teardown failed last poll leaves.
	# Relabel before comment here, unlike hand_back: a relabel that fails
	# dies before anything is written, so the next poll retries both
	# together rather than posting the comment a second time.
	if gh issue view "$number" --repo "$repo" --json labels |
		jq -e "any(.labels[]?; .name == \"$stuck_label\")" >/dev/null 2>&1; then
		log "#$number: already carries $stuck_label; clearing what is left of the dead run without writing to the tracker again"
	else
		if ! relabel_stuck; then
			die "#$number: could not relabel to $stuck_label; refusing to start a new ticket beside a dead run's wreckage"
		fi

		body="$run_dir/stuck-leftover.md"
		{
			printf '%s\n' \
				"The AFK agent found this ticket still claimed (\`$working_label\`) with a worktree left on disk by an earlier run that died before it could hand the ticket back. No pull request was open for \`$branch\`."
			printf '%s\n' ""
			if [ "$pushed_branch" -eq 1 ]; then
				printf '%s\n' \
					"The worktree is removed. The branch reached origin and is kept there - it holds the work the gate passed on, and a pull request can be opened from it by hand."
			elif [ "$rescued" -eq 1 ]; then
				printf '%s\n' \
					"The worktree is removed, but the branch \`$branch\` is kept **unpushed, in \`$checkout\` on the runner's host**: the run had uncommitted work in its worktree, and it is committed onto that branch as a single \`WIP\` commit rather than deleted with the directory. That commit has passed nothing - not the gate, not the path denylist, not CI, and no review - and it was never pushed, because the pre-push gate is the only thing that may authorise a push. Read it as a starting point or delete the branch."
			else
				printf '%s\n' \
					"The worktree and the branch are removed. There was no uncommitted work in the worktree to keep."
			fi
			printf '%s\n' ""
			printf '%s\n' \
				"The run's own state - its prompt, its logs, its attempt count - did not survive it, and is not recovered: resuming unattended work nobody can vouch for is the shape ADR 0004 §6 exists to prevent."
			printf '%s\n' ""
			stuck_closing
		} >"$body"

		post_tracker_comment "$body"

		notify_stuck \
			"An earlier run of the AFK agent died on this ticket with a worktree left behind; the ticket has been handed back for a human decision." \
			"$(if [ "$pushed_branch" -eq 1 ]; then printf '%s reached origin and is kept' "$branch"; else printf 'Nothing of the dead run was kept.'; fi)"
	fi

	# Delete the local branch only when there is nothing on it worth
	# keeping: not when it reached origin, and not when the rescue above
	# just put the dead run's work on it.
	if [ "$pushed_branch" -eq 1 ] || [ "$rescued" -eq 1 ]; then
		remove_worktree_and_branch "$path" "$branch" 0
	else
		remove_worktree_and_branch "$path" "$branch" 1
	fi
}
