# shellcheck shell=bash
# --- the revision loop (#196) ----------------------------
#
# A second entry point on this runner. The first is the ticket queue
# above; this one starts from a pull request this pipeline opened, which
# a person has reviewed and labelled `$revise_label`. The label is the
# whole of the trigger: not the presence of unresolved threads, which
# would start a run on a half-written review, and not anything the
# runner infers. A person applies it when their review is done, and the
# runner takes it from there.
#
# What this stage is NOT is the fix-and-recheck item 6 rejected. That
# handed the *reviewer's* findings - the advisory stage's own output -
# back to the model that wrote the code, and it was measured: 15 runs,
# 0 catches, refusals grounded on true but immaterial observations. This
# hands back the *human's* findings, the most reliable input in the
# pipeline and the only one that had no path to the code. The
# distinction is structural, not prose, and it is held at three places:
#
# - The poll asks the tracker for the pull request's comments and review
#   summaries, and for the inline review comments beside them. It never
#   requests the pull request's body, and the author filter below is what
#   keeps the advisory review's findings out of what is fed back: since
#   #202 they arrive as a comment posted by the agent's own account, so
#   the same filter that drops the round comments drops them too. Not
#   reading the body remains a property of the query, not of the code's
#   discipline.
# - The author filter (`$bot_login`, ADR 0006) drops everything the
#   agent itself wrote, which includes every round comment this loop
#   has posted - so a round is fed only the comments written since the
#   last one, and never its own output from a previous round.
# - The revision prompt repeats the boundary: the comments below it are
#   the only review input, and the agent's own comments are off limits.
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
# push after the revision must land on top of it.
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
	# --- poll ------------------------------------------------------------
	#
	# Only pull requests on this runner's own branches are considered: the
	# branch prefix is what the original run cut and what no other
	# workflow here creates, and the slug is validated against the same
	# regex the ticket lane builds it with. Open only, oldest first, and
	# the body is deliberately not in the field list.
	log "polling $repo for open '$revise_label' pull requests"

	revise_candidates="$(
		gh pr list \
			--repo "$repo" \
			--label "$revise_label" \
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
	log "$revise_total labelled pull request(s)"

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

	# The budget's stuck path, reached before anything is claimed: a
	# labelled pull request whose rounds are already spent gets the same
	# three writes every hand-back makes - comment, relabel, notification -
	# and the run ends red, because a human owes it a decision. Relabel
	# before comment, like the dead-run guard: a relabel that fails dies
	# before anything is written, so the next poll retries both together
	# rather than posting the comment a second time.
	#
	# The run-ends-red part is the run's whole shape, not just this pull
	# request's: one poll handles one pull request, so a spent budget
	# blocks revisable ones behind it for one poll. Fine at concurrency
	# 1, which is all this runner has; revisit if that ever changes.
	revise_stuck_budget() {
		local body="$run_dir/stuck-revise.md"

		{
			printf '%s\n' "The AFK agent is handing this pull request back without running another revision round."
			printf '%s\n' ""
			printf '%s\n' \
				"This pull request has had $max_revision_rounds revision round(s), and further rounds do not run. Each round is a session, a gate, a push and a CI watch; a disagreement between a reviewer and the model is otherwise unbounded spend."
			printf '%s\n' ""
			printf '%s\n' "The pull request is relabelled \`$stuck_label\`. Address the review comments by hand, or close the pull request: re-applying \`$revise_label\` will not start another round."
		} >"$body"

		if ! gh pr edit "$number" --repo "$repo" \
			--remove-label "$revise_label" --add-label "$stuck_label"; then
			die "#$number: could not relabel to $stuck_label; refusing to leave it in the revision queue"
		fi

		post_tracker_comment "$body"

		notify_stuck \
			"the revision budget is spent on this pull request; further rounds do not run" \
			"$pr_url is open and unfinished"
		exit 1
	}

	# The comments, collected per candidate BEFORE the claim, for the same
	# reason the ticket lane filters before it claims: a pull request whose
	# only comments are the agent's own must start no session, and a pull
	# request whose rounds are spent must not be claimed to be stuck. Two
	# calls: `pr view` for the review summaries and the issue comments,
	# and the REST endpoint for the inline review comments, which
	# `pr view` does not carry. The body is not asked for.
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
        # Anchored: only the round comments this loop posts count, not the
        # hand-back prose, which also says "revision round" somewhere in it
        # but never as its own first line.
        | ([ $mine[] | select(.body | test("^AFK agent: revision round")) | .at ] | max // "") as $since
        | [$human[] | select(.at > $since)] | sort_by(.at)
        | { rounds: [$mine[] | select(.body | test("^AFK agent: revision round"))] | length,
            count: length,
            prose: (map("### \(.author) - \(.where)\n\n\(.body)") | join("\n\n---\n\n")) }
      ' <<<"$pr_json"
	}

	revise_pick=""
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

		if [ "$(jq -r '.rounds' <<<"$revise_comments")" -ge @MAX_REVISION_ROUNDS@ ]; then
			log "#$number: $max_revision_rounds revision round(s) already recorded; the budget is spent"
			revise_stuck_budget
		fi

		if [ "$(jq -r '.count' <<<"$revise_comments")" -eq 0 ]; then
			log "#$number: no comments from accounts other than the agent's own; starting no session"
			continue
		fi

		revise_pick="$revise_candidate"
		jq -r '.prose' <<<"$revise_comments" >"$run_dir/revision-comments.md"
		break
	done

	if [ -z "$revise_pick" ]; then
		log "nothing to revise this poll"
		exit 0
	fi

	# --- claim, isolate, revise -------------------------------------------
	#
	# The claim is one edit, like the ticket lane's, so a pull request that
	# is being revised is never briefly in the queue and out of it. A
	# failed edit leaves the pull request labelled and unclaimed - the next
	# poll will try again - so nothing is undone and nothing is stranded.
	log "revising #$number: $title"
	if ! gh pr edit "$number" --repo "$repo" \
		--remove-label "$revise_label" --add-label "$working_label"; then
		die "#$number: could not claim the pull request; nothing was tried, so the next poll will try again"
	fi

	unclaim_pr_and_die() {
		if ! gh pr edit "$number" --repo "$repo" \
			--remove-label "$working_label" --add-label "$revise_label"; then
			echo "afk-agent: #$number: could not undo the claim either; the pull request carries $working_label and is invisible to the revision queue" >&2
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
	git -C "$checkout" worktree add -B "$branch" "$worktree" "origin/$branch" ||
		unclaim_pr_and_die "resuming $branch at $worktree failed; the claim is undone and the next poll will try again"

	log "claimed #$number, resuming $branch at its head, in $worktree"

	# --- the revision session, on the implement stage's retry budget ------
	#
	# Same loop, same gate, same verdict, same retry shape (ADR 0004 §6):
	# a round that fails its gate costs a retry, not a round. The opening
	# message is the revision prompt plus the collected comments; the
	# retries carry the gate's verdict, exactly as the implement stage's
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

	round=$(($(jq -r '.rounds' <<<"$revise_comments") + 1))

	message="$(cat "$revise_dir/message")"

	while :; do
		log "#$number: revision round $round of @MAX_REVISION_ROUNDS@, attempt $attempt of @MAX_ATTEMPTS@"

		opencode_args=(--agent build --model @MODEL@ --variant @VARIANT@)
		if [ -n "$revise_session" ]; then
			opencode_args+=(--session "$revise_session")
		else
			opencode_args+=(--title "$revise_title")
		fi

		revise_rc=0
		(
			cd "$worktree" || exit 1
			OPENCODE_CONFIG_CONTENT=@PERMISSION_OVERLAY@ \
				timeout @ATTEMPT_TIMEOUT@ opencode run --auto \
				--dir "$worktree" "${opencode_args[@]}" "$message"
		) || revise_rc=$?

		# Judged against the pull request's head, which is what the round
		# resumed from: what has to be true here is that something NEW was
		# committed on top of it.
		attempt_verdict "$revise_rc" "origin/$branch"

		if [ -z "$reason" ]; then
			log "#$number: revision attempt $attempt passed the gate"
			break
		fi

		log "#$number: revision attempt $attempt did not pass, because $reason"

		if [ "$attempt" -ge @MAX_ATTEMPTS@ ]; then
			hand_back "@MAX_ATTEMPTS@ revision attempt(s) and no passing change; the last one failed because $reason"
		fi

		if [ -z "$revise_session" ]; then
			revise_session="$(session_id_for "$worktree" "$revise_title")"
		fi

		if [ -n "$revise_session" ]; then
			log "#$number: retrying inside session $revise_session"
			message="$(printf '%s\n\n%s' \
				"Revision attempt $attempt of @MAX_ATTEMPTS@ did not pass, because $reason" \
				"Fix that here, in this worktree, and commit the fix. The gate is the only thing that decides whether this revision round is done.")"
		elif [ "$revise_rc" -eq 0 ] || [ "$committed" -gt 0 ]; then
			hand_back "revision attempt $attempt ran, but no session titled '$revise_title' can be found to continue; refusing to retry in a fresh context (ADR 0004 §6)"
		else
			log "#$number: revision attempt $attempt opened no session; the next one starts one"
			message="$(cat "$revise_dir/message")"
		fi

		attempt=$((attempt + 1))
	done

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
			"This round addressed the review comments on this pull request from accounts other than the agent's own. The change passed the local gate and was pushed to \`$branch\` on top of what the reviewer read. What follows is the revision session's own account of what it addressed and what it did not, unedited:"
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

		ci_fix_rc=0
		(
			cd "$worktree" || exit 1
			OPENCODE_CONFIG_CONTENT=@PERMISSION_OVERLAY@ \
				timeout @ATTEMPT_TIMEOUT@ opencode run --auto \
				--dir "$worktree" \
				--agent build --model @MODEL@ --variant @VARIANT@ \
				--session "$revise_session" "$ci_message"
		) || ci_fix_rc=$?

		attempt_verdict "$ci_fix_rc" "$pushed_head"
		[ -z "$reason" ] ||
			hand_back "the CI fix did not pass, because $reason. $pr_url is open with a red CI run on it; a CI fix gets one session and no retry (ADR 0007)"

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
		--remove-label "$working_label" --add-label "$handoff_label" ||
		hand_back "the revision is green, but $pr_url could not be relabelled for the reviewer"

	notify low white_check_mark "AFK agent: PR revised (#$number)" \
		"$(printf '%s\n%s' \
			"$pr_url" \
			"revision round $round of @MAX_REVISION_ROUNDS@ addressed the review comments; CI is green")"

	git -C "$checkout" worktree remove "$worktree" ||
		die "#$number: $pr_url is revised and green, but $worktree could not be removed; the next poll's guard clears it without touching the pull request"

	log "#$number: revision round $round complete - $pr_url is back with the reviewer. Merging it is a human act (ADR 0004 §9), and nothing here does it"
fi
