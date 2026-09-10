# shellcheck shell=bash
# --- what item 4 hands over ------------------------------------------
#
# Asserted before anything is polled or claimed, so that a missing
# credential or a tool that fell off the unit's PATH fails on an empty
# tracker rather than halfway through a claimed ticket. Names only, never
# values: this unit reads a PAT that can push to this repository, and the
# system journal is not a place to put it.

creds="${CREDENTIALS_DIRECTORY:?systemd passed no credentials directory}"

require_credential() {
	if [ ! -s "$creds/$1" ]; then
		echo "afk-agent: credential '$1' is missing or empty" >&2
		exit 1
	fi
	echo "afk-agent: credential '$1' present"
}

require_tool() {
	if ! command -v "$1" >/dev/null; then
		echo "afk-agent: tool '$1' is not on this unit's PATH" >&2
		exit 1
	fi
	echo "afk-agent: tool '$1' present"
}

@REQUIRE_CREDENTIAL_LINES@

@REQUIRE_TOOL_LINES@

# A shell that will actually run a command, which is not the same
# question as `bash` being on the PATH above and is why this is asked
# separately. opencode spawns `$SHELL` for every bash call the model
# makes, so a `$SHELL` that refuses leaves the model unable to read a
# file, run a test or make a commit - while every `gh` and `git` call
# this script makes itself keeps working, because none of them go
# through a shell. That asymmetry is what made it expensive to find: the
# run claims a ticket, clones, cuts a worktree, and only then discovers
# that the agent inside it can do nothing.
#
# Executable is not enough to test: `nologin` is executable, and exits 1
# with a message. So run something through it.
require_shell() {
	if [ -z "${SHELL:-}" ]; then
		echo "afk-agent: SHELL is unset; opencode's bash tool has no shell to spawn" >&2
		exit 1
	fi
	if ! "$SHELL" -c 'exit 0' >/dev/null 2>&1; then
		echo "afk-agent: SHELL is '$SHELL', which will not run a command - opencode's bash tool cannot work through it" >&2
		exit 1
	fi
	echo "afk-agent: shell '$SHELL' runs commands"
}

require_shell

# --- the credential, which expires part-way through a run -------------
#
# ADR 0006: the runner authenticates as a GitHub App, so what the secret
# store holds is a private key and what the API wants is an installation
# token minted from it. That token lives one hour, while `attemptTimeout`
# alone is 3600 and `maxRuntime` covers three attempts plus their gates -
# so a token expiring mid-run is the ordinary case here, not the
# exceptional one. Reading it once at startup would work all the way
# through the poll, the claim and the implement stage and then fail at
# the push, with a claimed ticket already behind it.
#
# So `gh` below is a shell function that refreshes first, and every `gh`
# in this script goes through it - which is why no call site has to think
# about token lifetime. `command gh` rather than a bare one, so the
# function does not call itself, and so the mock the check substitutes is
# still what runs.
#
# The cache is a file rather than a shell variable because most of the
# `gh` calls here are inside `$(...)`. A variable set by the refresh would
# be set in the subshell and discarded with it, so the token would be
# re-minted on every single call rather than once an hour. The file is 0600 under a 0700 StateDirectory, and
# the trap removes it - a token that outlives the run that minted it is a
# standing credential, which is the property this design is meant not to
# have.
#
# Nothing here is echoed. The key reaches openssl on a path and the token
# reaches `gh` through the environment; neither is ever a log line or a
# command-line argument.
app_id="@APP_ID@"
token_cache="$state_dir/installation-token"
mkdir -p "$state_dir"
trap 'rm -f "$token_cache"' EXIT

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

refresh_gh_token() {
	local now expires header payload signing_input signature jwt installation token

	now="$(date +%s)"
	if [ -s "$token_cache" ]; then
		expires="$(head -n 1 "$token_cache")"
		if [ "$now" -lt "$expires" ]; then
			GH_TOKEN="$(tail -n 1 "$token_cache")"
			export GH_TOKEN
			return 0
		fi
	fi

	# `iat` is backdated a minute because GitHub rejects a JWT whose clock
	# runs ahead of its own, and ten minutes is the longest expiry it will
	# accept. This JWT authenticates as the App itself and can do nothing
	# to the repository; only the token it is exchanged for can.
	header='{"alg":"RS256","typ":"JWT"}'
	payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
		"$((now - 60))" "$((now + 540))" "$app_id")"
	signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
	signature="$(printf '%s' "$signing_input" |
		openssl dgst -sha256 -sign "$creds/github-app-key" -binary | b64url)" ||
		die "the App private key would not sign a JWT; it is not a usable RSA key"
	jwt="$signing_input.$signature"

	installation="$(curl -sS \
		-H "Authorization: Bearer $jwt" \
		-H 'Accept: application/vnd.github+json' \
		https://api.github.com/app/installations | jq -r '.[0].id // empty')" ||
		die "could not ask GitHub where this App is installed"
	[ -n "$installation" ] ||
		die "this App has no installations; it has to be installed on $repo before the runner can act as it"

	token="$(curl -sS -X POST \
		-H "Authorization: Bearer $jwt" \
		-H 'Accept: application/vnd.github+json' \
		"https://api.github.com/app/installations/$installation/access_tokens" |
		jq -r '.token // empty')" ||
		die "could not mint an installation token for installation $installation"
	[ -n "$token" ] ||
		die "GitHub returned no installation token; the App's permissions may have been withdrawn"

	# Fifty minutes against GitHub's sixty, so that no single `gh` call can
	# outlive the token it started with.
	printf '%s\n%s\n' "$((now + 3000))" "$token" >"$token_cache"
	GH_TOKEN="$token"
	export GH_TOKEN
}

gh() {
	refresh_gh_token
	command gh "$@"
}

# The one seam the check needs: it drives a mocked `gh` against a fixture
# origin and has no App key to mint from. Everything else about the
# credential path - that the key is required, that `gh` refreshes before
# it runs, that the push refreshes too - is under test as written.
if [ -n "${AFK_GH_TOKEN:-}" ]; then
	export GH_TOKEN="$AFK_GH_TOKEN"
	refresh_gh_token() { :; }
fi

export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1

# Exported rather than written into the checkout's config, so that it
# covers every `git` the agent runs as well as every one this script
# runs, and so that nothing has to be undone if a worktree outlives the
# run that made it.
export GIT_AUTHOR_NAME=@COMMIT_NAME@
export GIT_AUTHOR_EMAIL=@COMMIT_EMAIL@
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# OpenCode reads its provider credentials from a file under the data
# directory, not from the environment, and this account has never run
# `opencode auth login`. So the credential
# is written into the shape opencode looks
# for, on every run rather than once, so that a rotated secret takes
# effect at the next poll rather than at whatever point somebody
# remembers this file exists. 0600 through the unit's UMask, under
# StateDirectory 0700; the value is never echoed.
#
# `opencode-username` is deliberately not wired to anything. Nothing on
# the headless path consumes it - not `opencode run`, not `opencode
# session`, not `opencode export`; the `--username` flag belongs to
# `--attach`, which this never uses. It stays declared and asserted:
# dropping a credential a later stage might want is the harder mistake
# to undo.
auth_dir="$state_dir/.local/share/opencode"
mkdir -p "$auth_dir"
jq -n --arg key "$(cat "$creds/opencode-api-key")" \
	'{"opencode-go": {type: "api", key: $key}}' >"$auth_dir/auth.json"

# Per-run scratch: prompts, gate logs, the pull request body, and the
# stuck path's comment bodies. Created before the guard, because the
# guard's hand-back writes into it.
run_dir="$state_dir/run"
rm -rf "$run_dir"
mkdir -p "$run_dir"

# The ntfy token, as the header file `notify` reads. Written once per
# run rather than read per notification - it is read from
# $CREDENTIALS_DIRECTORY, which does not change under a running unit -
# and through a file rather than curl's argv, for the reason `notify`
# gives. Never echoed: the value reaches the file and stops there.
printf 'Authorization: Bearer %s\n' "$(cat "$creds/ntfy-token")" \
	>"$run_dir/ntfy-auth"

# --- one ticket at a time --------------------------------------------
#
