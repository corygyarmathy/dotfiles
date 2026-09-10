# shellcheck shell=bash
# Rule 1 of docs/agents/afk-eligibility.md again, and this time against
# the thing that will actually be pushed. The pre-claim check reads
# a ticket's prose, which is all there is before a line of code exists;
# whether a diff is additions-only to one list in one file is a question
# about a diff that did not exist at claim time, and the harness pins
# that limit with a ticket that plainly means to edit ci.yml and never
# writes the path.
#
# THIS IS THE ONLY CONTROL, not an extra one. `AFK_AGENT_TOKEN` carries
# the Workflows permission precisely so the ci.yml matrix
# exception can be exercised, so nothing at GitHub's end refuses a push
# that edits a workflow file. And after the push there is nothing left to
# gate: a pushed branch becomes a pull request, a `pull_request` event
# runs the workflow file *from the head branch* with this repository's
# secrets, and `deploy` - the only ref the fleet follows - is a
# fast-forward away from any credential with write access. The pull
# request could be read, rejected and closed with all three hosts already
# moved (afk-eligibility.md, "Why these three").
#
# A FUNCTION CALLED FROM ONE PLACE, and that place is the line above the
# push. ADR 0007 §6 makes that structural rather than incidental: this
# run pushes more than once now - a CI fix round pushes to the same
# branch - and every one of those pushes has to be gated, because it is
# the push and not the pull request that makes a workflow file
# executable. `push_branch` below is the only caller and it does these
# two things and nothing else, so "immediately before, with nothing in
# between" is a property of that function rather than of anybody's care.
#
# Every refusal here is a stuck-path exit (#175): the hand-back
# comments on the ticket with this gate's verdict, relabels it, and tears
# down what nothing points at. On a first push that is everything the
# run built; on a CI fix's push the pull request is already open, and the
# hand-back reaches it too - the cost ADR 0007 accepted.
push_gate() {
	local changed path base_ci added removed name

	# Three dots. `origin/$base_branch` has been moving underneath this run
	# for as long as the ticket took, and a two-dot diff would read every
	# commit master gained meanwhile as this branch's work, reversed - so a
	# merge into master that touched `secrets/` would look like this branch
	# deleting it.
	changed="$(git -C "$worktree" diff --name-only "origin/$base_branch...HEAD")"

	while IFS= read -r path; do
		[ -n "$path" ] || continue
		case "$path" in
		secrets/* | .sops.yaml)
			hand_back "refusing to push $branch - its diff changes '$path', which no AFK diff may touch and which has no exception (docs/agents/afk-eligibility.md rule 1)"
			;;
		# The one file with an exception, checked below rather than here.
		.github/workflows/ci.yml) ;;
		.github/workflows/*)
			hand_back "refusing to push $branch - its diff changes '$path'. The only workflow file an AFK diff may touch is ci.yml, and only its checks matrix (docs/agents/afk-eligibility.md)"
			;;
		esac
	done <<<"$changed"

	grep -qxF ".github/workflows/ci.yml" <<<"$changed" || return 0

	log "#$number: the diff changes ci.yml, so the checks-matrix exception is what has to hold"

	# A diff that deletes ci.yml outright, which is neither an addition to
	# the matrix nor something the reads below could survive: every one of
	# them is a `yq` against a file that is no longer there, and an
	# unguarded `yq` here would abort the runner with none of this
	# explanation. The pre-claim gate reads the same file and would already
	# have failed on it, which is why this is one line rather than a case in
	# the harness.
	[ -f "$worktree/.github/workflows/ci.yml" ] ||
		hand_back "refusing to push $branch - its diff deletes .github/workflows/ci.yml, and the only change the exception allows is an addition to one list in it"

	base_ci="$run_dir/ci-base.yml"
	git -C "$worktree" show "origin/$base_branch:.github/workflows/ci.yml" >"$base_ci" 2>/dev/null ||
		hand_back "refusing to push $branch - it adds .github/workflows/ci.yml rather than amending the one on $base_branch, and the exception is written against a file that already exists"

	# "Nothing else in ci.yml may differ", asked by normalising the one
	# list that may differ away and comparing what is left. `yq` on both
	# sides rather than a textual diff, because a re-indented or re-quoted
	# file is not a changed one - and the same tool ci.yml's own lint job
	# uses, so the two readings cannot disagree about what the file says.
	#
	# Its limit is written down in afk-eligibility.md and accepted there:
	# yq drops comments on both sides, so a comment-only edit passes.
	# Comments do not execute.
	yq "del(.jobs.checks.strategy.matrix.check)" "$base_ci" >"$run_dir/ci-base.normalised"
	yq "del(.jobs.checks.strategy.matrix.check)" "$worktree/.github/workflows/ci.yml" \
		>"$run_dir/ci-head.normalised"
	diff -u "$run_dir/ci-base.normalised" "$run_dir/ci-head.normalised" \
		>"$run_dir/ci-normalised.diff" ||
		hand_back "$(printf 'refusing to push %s - its ci.yml differs outside jobs.checks.strategy.matrix.check, which is the whole of what the exception allows:\n\n%s' \
			"$branch" "$(cat "$run_dir/ci-normalised.diff")")"

	yq -r ".jobs.checks.strategy.matrix.check[]" "$base_ci" |
		LC_ALL=C sort >"$run_dir/matrix-was"
	yq -r ".jobs.checks.strategy.matrix.check[]" "$worktree/.github/workflows/ci.yml" |
		LC_ALL=C sort >"$run_dir/matrix-now"

	# Additions only. An entry removed silently stops a check from running,
	# which is the "gate that quietly stops gating" failure ci.yml's own
	# lint job exists to catch; an entry altered is a removal and an
	# addition, so this catches that too.
	removed="$(comm -23 "$run_dir/matrix-was" "$run_dir/matrix-now")"
	[ -z "$removed" ] ||
		hand_back "refusing to push $branch - its ci.yml diff removes $(tr '\n' ' ' <<<"$removed")from the checks matrix, and a check that stops being listed stops running"

	added="$(comm -13 "$run_dir/matrix-was" "$run_dir/matrix-now")"

	# What the flake actually exposes, re-derived here rather than read
	# from the file the implement gate left behind. That gate already
	# demands the matrix and this list agree exactly, which makes the
	# second half of the loop below redundant today - and that is the
	# point. This check is the last one standing between a workflow edit
	# and a run holding the repository's secrets, so it must not be a
	# reading of another check's homework.
	(cd "$worktree" &&
		nix eval --raw .#checks.x86_64-linux \
			--apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)') |
		LC_ALL=C sort >"$run_dir/push-checks" ||
		hand_back "refusing to push $branch - the flake's own checks could not be listed, so an added matrix entry cannot be checked against them"

	while IFS= read -r name; do
		[ -n "$name" ] || continue

		# The character class, and it is not belt-and-braces: a matrix entry
		# is interpolated straight into a `run:` script by ci.yml, so it is
		# shell context rather than data, and Nix attribute names can carry
		# arbitrary characters when quoted.
		[[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] ||
			hand_back "refusing to push $branch - its ci.yml diff adds the matrix entry '$name', which is not a safe name; entries are interpolated into a shell script by the workflow"

		grep -qxF "$name" "$run_dir/push-checks" ||
			hand_back "refusing to push $branch - its ci.yml diff adds the matrix entry '$name', which names no check this flake exposes"
	done <<<"$added"

	log "#$number: the ci.yml diff is additions-only to the checks matrix, adding $(tr '\n' ' ' <<<"$added")"
}

# --- rebase onto the moved base ---------------------------------------
#
