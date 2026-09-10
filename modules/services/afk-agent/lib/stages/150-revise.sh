# shellcheck shell=bash
# --- the revision loop (#196, as re-triggered by #247) --------------------
#
# A second entry point on this runner. The first is the ticket queue
# above; this one starts from a pull request this pipeline opened, on
# which a person has written a `/revise` comment. The comment is the
# whole of the trigger: not the presence of unresolved threads, which
# would start a run on a half-written review, and not anything the
# runner infers. The poll in 50 checked this frontier before it claimed
# any ticket work - a human waiting on a revision is ahead of a backlog
# ticket - and it did so with the same queries this stage would have
# run, so the pick is already made: the pull request, its branch, and
# the round's input, collected below the claim.
#
# What this stage is NOT is the fix-and-recheck item 6 rejected. That
# handed the *reviewer's* findings - the advisory stage's own output -
# back to the model that wrote the code, and it was measured: 15 runs,
# 0 catches, refusals grounded on true but immaterial observations. This
# hands back the *human's* findings, the most reliable input in the
# pipeline and the only one that drives the round's address list - the
# advisory findings may be read, but nothing feeds them in unchosen. The
# distinction is structural in what drives a round, and it is held at
# three places:
#
# - The frontier query asks the tracker for the pull request's comments
#   and review summaries, and for the inline review comments beside
#   them. It never requests the pull request's body. The author filter
#   below is what keeps the advisory review's findings out of what is
#   fed back: since #202 they arrive as a comment posted by the agent's
#   own account, so the same filter that drops the round comments drops
#   them too. Not reading the body remains a property of the query, not
#   of the code's discipline.
# - The author filter (`$bot_login`, ADR 0006) drops everything the
#   agent itself wrote, which includes every round comment this loop
#   has posted - so a round is fed only the comments written since the
#   last one, and never its own output from a previous round.
# - The revision prompt repeats the boundary: what follows it is the
#   input the round was started with, and what its author will judge the
#   round against - and the agent's own words in the thread are
#   background to read, never instructions that drive the round.
# - The session may read the pull request itself: `gh pr view` is
#   allowed in permissionOverlay (`gh pr view*` beside a `gh pr *` deny
#   that sorts before it), carved out of the write verbs. A
#   `/revise` comment may reference the findings without quoting them -
#   "address findings 1-6, not 7" - and the reference has to resolve to
#   something the round can read. What the overlay still holds is every
#   write verb: the round's prose reaches the pull request only through
#   the runner's round comment, past the gate and the push.
#
# The pull request is resumed at its head rather than claimed fresh: the
# worktree is cut at `origin/$branch`, which is what the reviewer read.
# The branch is the one the original run cut, so its name - and with it
# the worktree's name and the in-flight guard's parsing - is exactly the
# ticket slug the guard already understands, and a revision run that
# dies leaves the same shape of leftover as any other run. `-B` resets
# the local branch to the pull request's head before checking it out,
# which is what "resume at the PR head" means when the local branch and
# origin can disagree: origin is what the pull request is from, and the
# push after the revision is leased to it (`--force-with-lease`, in
# `push_branch`): it refuses a head nobody else pushed, and permits the
# rewriting of this branch's own agent-authored commits - amend, rebase -
# that a review round is otherwise forced to awkward extra commits for.
#
# The denylist is re-derived rather than inherited. The prose checks that
# guard a ticket's body deliberately do NOT run here - the pull request's
# body quotes commit messages written under a prompt that names the
# denied paths, so a prose match there would refuse this loop's own pull
# requests forever. The enforcement is the one that reads the diff:
# `push_gate`, immediately before the push, against the diff that is
# actually being revised. That gate is a function call away from the
# push inside `push_branch`, so nothing else had to change to make it
# hold.
#
# Three rounds per pull request, then the stuck path. The count is read
# from the tracker rather than kept anywhere local, because the runner
# has no memory between runs: each round ends with a comment whose first
# line names itself, and the count is of those comments. A round whose
# comment could not be posted is a handed-back run, for the same reason
# every hand-back is one - a comment that was never written is gone for
# good.
#
# A round that fails its gate consumes a retry, not a round: the retry
# budget below is the implement stage's own (`$attempt`, `@MAX_ATTEMPTS@`,
# same session), and a round is counted only once its commit is pushed
# and its comment posted. No review stage runs again - the reviewer's
# comments are the review this round responds to - and the hand-off
# label goes back on in one edit once CI is green, which is the same
# condition it was first applied under.
if [ "$flow" = revise ]; then
	# --- claim, isolate, revise -------------------------------------------
	#
	# The claim is one edit, like the ticket lane's, so a pull request that
	# is being revised is never briefly in the frontier and out of it. A
	# failed edit leaves the pull request labelled and unclaimed - the
	# next poll will try again - so nothing is undone and nothing is
	# stranded.
	log "revising #$number: $title"
	if ! gh pr edit "$number" --repo "$repo" \
		--remove-label "$handoff_label" --add-label "$revising_label"; then
		die "#$number: could not claim the pull request; nothing was tried, so the next poll will try again"
	fi

	unclaim_pr_and_die() {
		if ! gh pr edit "$number" --repo "$repo" \
			--remove-label "$revising_label" --add-label "$handoff_label"; then
			echo "afk-agent: #$number: could not undo the claim either; the pull request carries $revising_label and is invisible to the revision frontier" >&2
		fi
		die "$1"
	}

	if [ ! -d "$checkout/.git" ]; then
		log "cloning $repo_url into $checkout"
		git clone "$repo_url" "$checkout" ||
			unclaim_pr_and_die "cloning $repo_url failed; the claim is undone and the next poll will try again"
	fi

	git -C "$checkout" fetch --prune origin ||
		unclaim_pr_and_die "fetching $repo_url failed; the claim is undone and the next poll will try again"

	if ! git -C "$checkout" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
		hand_back "the pull request's branch $branch is not on origin, so there is nothing to resume"
	fi

	# `-B`, not `-b`: the branch exists locally (the original run kept it),
	# and a human may have pushed to the pull request since, so the local
	# ref is reset onto the PR head before the worktree is cut from it.
	# Origin is never rewritten by this; only the local ref moves, and only
	# onto origin.
	worktree="$worktrees/$slug"
	# The lease the pushes carry: the origin head the round resumed at,
	# whatever the session does to the local branch - plain commit, amend,
	# rebase - on top of it. `push_branch` advances it on every landing, so a
	# CI fix round's second push leases to the revision's own pushed head.
	push_lease="$(git -C "$checkout" rev-parse "refs/remotes/origin/$branch")"
	git -C "$checkout" worktree add -B "$branch" "$worktree" "origin/$branch" ||
		unclaim_pr_and_die "resuming $branch at $worktree failed; the claim is undone and the next poll will try again"

	log "claimed #$number, resuming $branch at its head, in $worktree"

	# The reply to the `/revise` comment: the human-facing half of the
	# claim, so the request is answered where it was made. The claim edit
	# above is the durable half - it is what keeps the same request from
	# being picked again while this round runs - so a reply that fails is
	# journal noise rather than a lost round: the round comment at the end
	# is what the next poll counts. It is posted only once the worktree
	# has actually resumed: everything before that point can still undo
	# the claim and hand the request back to the next poll, and a reply
	# that outlived its own undo would be posted twice.
	claim_reply="$run_dir/claim-reply.md"
	printf '%s\n' \
		"Revision round $((revise_rounds + 1)) of @MAX_REVISION_ROUNDS@ has started on this pull request, in reply to @$revise_author's \`/revise\` comment." \
		>"$claim_reply"

	gh pr comment "$number" --repo "$repo" --body-file "$claim_reply" ||
		echo "afk-agent: #$number: the claim reply could not be posted on $pr_url; the round runs regardless" >&2

	# --- the revision session, on the implement stage's retry budget ------
	#
	# The loop is the shared one (65-attempt-loop.sh), so the gate, the
	# verdict and the retry shape are literally the same code (ADR 0004 §6):
	# a round that fails its gate costs a retry, not a round. The opening
	# message is the revision prompt plus the round's input - the `/revise`
	# request's own text, or the review comments behind it; the retries
	# carry the gate's verdict, exactly as the implement stage's
	# do. When the session that built this branch can still be found - the
	# worktree path is the one it ran in, so the project-scoped session
	# list can see it - the round continues it rather than starting fresh.
	revise_dir="$run_dir/revision"
	mkdir -p "$revise_dir"
	revise_title="$slug-revise"

	sed "s/PRNUMBER/$number/g" @REVISE_PROMPT@ >"$revise_dir/prompt"
	{
		cat "$revise_dir/prompt"
		printf '\n---\n\n'
		cat "$run_dir/revision-comments.md"
	} >"$revise_dir/message"

	revise_session="$(session_id_for "$worktree" "$slug")"
	if [ -n "$revise_session" ]; then
		log "#$number: continuing the session that built this branch ($revise_session)"
	else
		log "#$number: no session titled '$slug' to continue; the round opens a fresh one"
	fi

	round=$((revise_rounds + 1))

	# What is this lane's is the opening message and the wording its retries
	# carry; the seed is the session that built the branch, and the fresh
	# title is the round's own.
	attempt_label="revision round $round of @MAX_REVISION_ROUNDS@, attempt"
	session="$revise_session"
	attempt_loop \
		"$attempt_label" \
		"$(cat "$revise_dir/message")" \
		"$revise_title" \
		"origin/$branch" \
		@MAX_ATTEMPTS@ \
		"Revision attempt" \
		"this revision round is done" \
		"@MAX_ATTEMPTS@ revision attempt(s) and no passing change; the last one failed because %s"
	revise_session="$session"

	log "#$number: revision attempt $attempt passed the gate"

	# The round report: the session's own account of what it addressed and
	# what it did not, read out of the transcript rather than the session's
	# stdout, for the same reason the review stage reads its findings this
	# way. It is posted verbatim; the runner's only contribution is the
	# framing above and below it.
	if [ -z "$revise_session" ]; then
		revise_session="$(session_id_for "$worktree" "$revise_title")"
	fi
	[ -n "$revise_session" ] ||
		hand_back "the revision exited 0 but no session titled '$revise_title' can be found, so there is no transcript to read the round report from"

	(cd "$worktree" && opencode export "$revise_session") \
		>"$revise_dir/session.json" 2>/dev/null || true

	jq -e 'has("messages") and (.messages | type == "array")' \
		"$revise_dir/session.json" >/dev/null 2>&1 ||
		hand_back "the revision transcript at $revise_dir/session.json is not a readable session, so the round report cannot be read from it"

	revise_report="$(jq -r '[ .messages[]
	         | select(.info.role == "assistant")
	         | .parts[]? | select(.type == "text") | .text
	       ] | last // ""' "$revise_dir/session.json")"

	grep -q '[^[:space:]]' <<<"$revise_report" ||
		hand_back "the revision session produced no closing report, so the round has nothing to say about what it addressed"

	# --- gate, push, report ------------------------------------------------
	#
	# One function, gate and push with nothing between (ADR 0007 §6), and
	# the gate re-derived here against the revised diff - which is the
	# point of calling it again rather than trusting the round that
	# preceded the review.
	push_branch

	# The round comment: the durable half of the round, posted before
	# anything is watched or decided. Its first line is what the next
	# poll counts the rounds from, so a comment that cannot be posted is
	# a handed-back run rather than a silent one.
	revise_comment="$run_dir/round-comment.md"
	{
		printf '%s\n' "AFK agent: revision round $round of @MAX_REVISION_ROUNDS@."
		printf '%s\n' ""
		printf '%s\n' \
			"This round addressed the \`/revise\` request that started it, and the review comments behind it, from accounts other than the agent's own. The change passed the local gate and was pushed to \`$branch\`, behind a lease: it landed only because nobody has pushed to the branch since this round resumed at the commit the reviewer read, and the round's commit may therefore amend or replay the work the reviewer saw rather than only adding to it. What follows is the revision session's own account of what it addressed and what it did not, unedited:"
		printf '%s\n' ""
		printf '%s\n' "$revise_report"
	} >"$revise_comment"

	gh pr comment "$number" --repo "$repo" --body-file "$revise_comment" ||
		hand_back "the round comment could not be posted on $pr_url, and without it the next poll cannot tell this round from the one before"

	# --- CI on the revised commit ------------------------------------------
	#
	# The same watch the ticket lane runs, against the commit this round
	# pushed. A red run is fed back into the revision session once, judged
	# once, and never a second time - the same asymmetry ADR 0007 settled
	# for the ticket lane's fix rounds: the local gate has already passed
	# on this branch, so a fix that fails it is the model going backwards,
	# and there is a pull request a human can pick up.
	pushed_head="$(git -C "$worktree" rev-parse HEAD)"
	log "#$number: watching CI on $pushed_head"
	watch_ci "$pushed_head"

	if [ "$ci_state" != green ]; then
		case "$ci_state" in
		red)
			# As in the ticket lane: the fix below is judged and pushed
			# against $pushed_head, which the worktree and the gate are on
			# and a followed head is not - so a red verdict there is
			# handed back rather than fed to the revision session.
			if [ "$ci_watched" != "$pushed_head" ]; then
				hand_back "CI on $ci_watched is red ($ci_failed). $ci_watched is a head somebody else pushed while this revision was watched, and this worktree is not on it, so it is not this revision's to fix. $pr_url is open with the revision unverified"
			fi
			;;
		absent)
			hand_back "nothing has reported on $ci_watched after @CI_FIRST_CHECK_POLLS@ polls - either CI was never triggered for it, or GitHub could not be asked. Neither is something the diff can fix. $pr_url is open with the revision unverified"
			;;
		unsettled)
			hand_back "CI on $ci_watched has not settled after @CI_SETTLE_POLLS@ polls, and still has $ci_failed outstanding. $pr_url is open with the revision unverified"
			;;
		cancelled)
			hand_back "CI on $ci_watched was cancelled ($ci_failed), so it reached no verdict. $pr_url is open with the revision unverified, and a re-run is a human's call"
			;;
		esac

		log "#$number: CI is red on $ci_watched where the local gate passed. Not green: $ci_failed"

		[ -n "$revise_session" ] ||
			hand_back "CI is red on $pr_url, but no revision session can be found to fix it in; refusing to fix in a fresh context (ADR 0004 §6)"

		ci_message="$(printf '%s\n\n%s\n\n%s' \
			"The revision on this branch passed the local gate, but CI on $pr_url is red on the commit at the head of this branch, so this is something only CI sees: a cold runner, the sharded check matrix, and every host built from an empty store." \
			"$(printf 'These checks are not green:\n%s' "$ci_failed")" \
			"Fix it here, in this worktree, and commit the fix. Do not push and do not touch the pull request - this runner pushes your commit to the same branch afterwards. The local gate has to pass on your fix as well, and there is no retry: this round is judged once.")"

		# The fix round is the shared one (65-attempt-loop.sh): one build
		# session inside the revision session, judged against $pushed_head
		# once, and handed back if it did not pass - the same definition
		# the ticket lane's fix round runs on.
		ci_fix_round "$revise_session" "$ci_message"

		push_branch

		pushed_head="$(git -C "$worktree" rev-parse HEAD)"
		log "#$number: watching CI again on $pushed_head"
		watch_ci "$pushed_head"

		[ "$ci_state" = green ] ||
			hand_back "CI on $ci_watched is $ci_state after one fix ($ci_failed). $pr_url is open with the revision unverified"
	fi

	# --- hand back to the reviewer -----------------------------------------
	#
	# One edit, the same shape as every claim and hand-off in this
	# pipeline: the claim goes, the hand-off label comes back, and a pull
	# request is never briefly carrying both or neither. The review whose
	# findings sit in the comment above predates this round - the
	# reviewer's own comments are the review that superseded them - so
	# nothing is re-reviewed and the body is not rewritten.
	gh pr edit "$number" --repo "$repo" \
		--remove-label "$revising_label" --add-label "$handoff_label" ||
		hand_back "the revision is green, but $pr_url could not be relabelled for the reviewer"

	notify low white_check_mark "AFK agent: PR revised (#$number)" \
		"$(printf '%s\n%s' \
			"$pr_url" \
			"revision round $round of @MAX_REVISION_ROUNDS@ addressed the review comments; CI is green")"

	git -C "$checkout" worktree remove "$worktree" ||
		die "#$number: $pr_url is revised and green, but $worktree could not be removed; the next poll's guard clears it without touching the pull request"

	log "#$number: revision round $round complete - $pr_url is back with the reviewer. Merging it is a human act (ADR 0004 §9), and nothing here does it"
fi
