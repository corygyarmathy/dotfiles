# shellcheck shell=bash
# AGENTS.md's worktree-isolation pattern, with the worktrees gathered
# under one directory rather than dropped beside the checkout as siblings:
# that form exists for a human's interactive tree, and here it is what
# both the in-flight guard above and the stuck path's teardown (#175)
# need to be able to enumerate.
#
# The branch is cut from `origin/$base_branch` rather than from whatever
# the checkout happens to be sitting on, so a checkout left dirty or
# detached by an earlier run cannot leak into the next ticket's diff.
#
# All of it is the ticket lane's: the revision lane (150-revise.sh)
# resumes the pull request's own branch instead of cutting one, and
# reads `$flow` to step aside.
if [ "$flow" = issue ]; then
	slugify() {
		printf '%s' "$1" |
			tr '[:upper:]' '[:lower:]' |
			sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//' |
			cut -c1-48 |
			sed -e 's/-\+$//'
	}

	slug="$number-$(slugify "$title")"
	branch="$branch_prefix$slug"
	worktree="$worktrees/$slug"

	# The slug becomes both a git ref and a directory name, and its input is
	# an issue title. Checked rather than trusted, and checked against what
	# is allowed rather than against a list of what is not.
	if ! [[ "$slug" =~ ^[0-9]+(-[a-z0-9]+)*$ ]]; then
		hand_back "refusing to build a branch name from the title: '$slug' is not a safe slug"
	fi

	if [ ! -d "$checkout/.git" ]; then
		log "cloning $repo_url into $checkout"
		git clone "$repo_url" "$checkout" ||
			unclaim_and_die "cloning $repo_url failed; the claim is undone and the next poll will try again"
	fi

	git -C "$checkout" fetch --prune origin ||
		unclaim_and_die "fetching $repo_url failed; the claim is undone and the next poll will try again"

	if git -C "$checkout" show-ref --verify --quiet "refs/heads/$branch"; then
		hand_back "branch $branch already exists in $checkout, and this run did not cut it, so the ticket looks half-worked; the branch is left exactly as it was found"
	fi

	# --no-track is not a detail. Without it git sets the new branch's
	# upstream to origin/master, and a push - with git's default
	# push.default of `simple` - would then aim at master rather than at the
	# branch. Protection on master would refuse it, so the failure would be
	# loud rather than dangerous, but a runner whose push target depends on
	# a branch protection rule holding is the wrong shape.
	git -C "$checkout" worktree add --no-track -b "$branch" "$worktree" "origin/$base_branch" ||
		unclaim_and_die "cutting $branch at $worktree failed; the claim is undone and the next poll will try again"

	branch_created=1

	log "claimed #$number, isolated on $branch at $worktree"
fi

# --- implement, on a bounded retry budget -----------------------------
#
