Implement GitHub issue #ISSUE in this repository.

Use the `implement` skill, by name - call it rather than improvising
something equivalent. Read the ticket first: `gh issue view ISSUE`.

Scope:

- Work only inside this directory. Do not read, write or reason about any
  checkout above or beside it.
- Do not touch `secrets/`, `.sops.yaml`, or anything under
  `.github/workflows/` - with exactly one exception. If your change adds a
  file under `checks/`, add that check's name to
  `jobs.checks.strategy.matrix.check` in `.github/workflows/ci.yml` and
  change nothing else in that file: no other key, no existing entry
  altered or removed. The name must match `^[a-z][a-z0-9-]*$` and must be a
  check the flake actually exposes. A new check that is not in that matrix
  never runs, and CI fails the build for saying so.
- Do not push, do not open a pull request, and do not edit, close or
  comment on the issue. Later stages do all of that.
- Do not run `code-review`. Review is a separate pass, in its own context,
  after this one.
- Before you commit, run `nix fmt` (write mode) from the repo root, so
  formatting lands in your commits rather than as uncommitted drift the
  push cannot carry. Then commit your work to this branch before you
  finish. Uncommitted work does not exist: the next stage pushes commits,
  and nothing else.

The gate your work has to pass is this repository's own: `nix fmt -- --ci`,
a `nix build` of each check the flake exposes, a build of every host, and
agreement between the checks the flake exposes and the matrix in `ci.yml`.
`AGENTS.md` is the rest of the house style. You will be told what the gate
said and given two further attempts to fix it.

Run the checks one `nix build .#checks.x86_64-linux.<name>` at a time, and
do not run `nix flake check`. It evaluates every output of this flake in
one process and peaks around 8 GB on this host, which is enough to invoke
the kernel's OOM killer and lose your session and your uncommitted work
with it. That is measured, on a run that had finished the work and was
killed proving it.

Five ways real runs of this pipeline have produced work that looked
finished and was not. They are measured, not hypothetical:

- Sourcing a value from the right file is not the same as sourcing a value
  the consuming format can parse. Render the output and read it against
  the grammar of the tool that consumes it.
- An invariant explained correctly in a comment is not an invariant
  enforced in the right place. Check where the code runs, not what the
  prose beside it claims.
- "I verified this" is a claim to check, not a fact. Re-run the thing.
- A discrepancy noticed mid-run is routinely lost by the time the closing
  summary is written. Derive that summary from what you did, not from what
  the ticket said before you started.
- Narrow scope wins. A check that needs no separate script or package
  beats a wider one that is equally correct.
