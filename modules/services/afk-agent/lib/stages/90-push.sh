# shellcheck shell=bash
# The step `implement` never does (#174): everything above this line is
# reversible by deleting a directory.
#
# The gate is the first line of this function and the push is the last,
# with nothing between them (ADR 0007 §6). Called once for the branch's
# first push and once more for each CI fix round, so a fix that adds a
# workflow file is refused exactly as the original diff would have been.
#
# An explicit refspec rather than a bare `git push`: what gets pushed
# should not depend on push.default, nor on an upstream item 5 went out
# of its way not to set. Never `--force`, and never a refspec that could
# become one: a branch a human may already be reading is not rewritten
# underneath them (ADR 0007 §4).
#
# The credential reaches git through `gh`, which already holds it in the
# environment, rather than through a remote URL or a config file - so the
# token never lands in .git/config, in a URL git will echo on failure, or
# on a command line `ps` can read. The empty helper ahead of it is git's
# own idiom for "use this one and nothing inherited".
# `gh auth git-credential` runs in a shell of git's making and reads
# GH_TOKEN out of the environment, so it never passes through the wrapper
# above. This is the one call site that has to ask for itself - and a
# second or third push is further still from the last refresh, which is
# exactly where a one-hour token would have died.
push_branch() {
	push_gate

	log "#$number: pushing $branch"
	refresh_gh_token

	git -C "$worktree" \
		-c credential.helper= \
		-c credential.helper='!gh auth git-credential' \
		push origin "HEAD:refs/heads/$branch" ||
		if [ -n "$pr_url" ]; then
			hand_back "$branch did not push, so the CI fix never reached $pr_url - which is open, red, and now a commit behind this worktree"
		else
			hand_back "$branch did not push, so nothing was opened for it"
		fi

	# What separates the hand-backs from here on from every one before it:
	# the branch is on origin now, so pushed work is kept rather than
	# torn down, and once the pull request is open the hand-back reaches
	# it too.
	pushed=1
}

push_branch

# --- raise the pull request, before anything reviews it ----------------
#
