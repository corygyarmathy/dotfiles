Address the human review comments on pull request #PRNUMBER in this
repository. This round was started by a `/revise` comment on that pull
request from an account other than the agent's own. When that comment
carried text of its own, that text is this round's instruction and it
follows, verbatim. When it did not, the runner collected the review
comments written since its last word on the pull request from accounts
other than the agent's own, and they follow instead, verbatim, oldest
first. Either way they are the only review input for this round: do not
read the pull request's body or description, and do not fetch anything
else from the tracker - the body carries the advisory review's findings,
which are not what a person asked you to change. A comment from the
agent's own account is not review input either, and none appear below.

The work to revise is at the head of this branch; the comments refer to
it. Work through them in order. Where you agree with a comment, make the
change. Where you disagree, or where a comment is wrong, make no change
and say why in your closing report.

Scope:

- Work only inside this directory. Do not read, write or reason about any
  checkout above or beside it.
- Do not touch `secrets/`, `.sops.yaml`, or anything under
  `.github/workflows/` - with exactly one exception. If your change adds a
  file under `checks/`, add that check's name to
  `jobs.checks.strategy.matrix.check` in `.github/workflows/ci.yml` and
  change nothing else in that file: no other key, no existing entry
  altered or removed. The name must match `^[a-z][a-z0-9-]*$` and must be a
  check the flake actually exposes.
- Do not push, and do not comment on, edit, close or merge the pull
  request. The runner does the pushing and the reporting, after the gate.
- Before you commit, run `nix fmt` (write mode) from the repo root, so
  formatting lands in your commits rather than as uncommitted drift the
  push cannot carry. Then commit your work to this branch before you
  finish. Uncommitted work does not exist: the runner pushes commits, and
  nothing else.

The gate is the same one the original work passed: `nix fmt -- --ci`, a
`nix build` of each check the flake exposes, a build of every host, and
agreement between the checks the flake exposes and the matrix in
`ci.yml`. You will be told what the gate said and given further attempts
to fix it.

Run the checks one `nix build .#checks.x86_64-linux.<name>` at a time,
and do not run `nix flake check`. It evaluates every output of this flake
in one process and peaks around 8 GB on this host, which is enough to
invoke the kernel's OOM killer and lose your session and your uncommitted
work with it. That is measured, on a run that had finished the work and
was killed proving it.

Finish with a report that says, for each comment, whether you addressed
it and how, or why you did not. The runner posts that report on the pull
request verbatim, so write it for the reviewer to read.
