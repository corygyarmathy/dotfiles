# checks/afk-agent-tokens.nix
#
# The transitions that build hold the heavy-build token, as afk-agent
# registers them at the pinned revision.
#
# homelab01 gives heavy-build a capacity of one because it has room for one
# build at a time, and the module's token description and assertion name the
# transitions that hold it. Which transitions declare a token is afk-agent's
# to decide, and nothing the binary prints says - the VM check cannot see it,
# and a token the capacity map lacks only surfaces after `afk work` has
# reached GitHub. So this compiles a test into the pinned source and asks the
# registry directly: a lock bump that drops a building transition's token, or
# renames the token, fails here instead of running two builds on the host.
{ self }:
self.packages.x86_64-linux.afk-agent.overrideAttrs (old: {
  pname = "check-afk-agent-tokens";

  postPatch = (old.postPatch or "") + ''
    mkdir internal/dotfilescheck
    cp ${./afk-agent-tokens_test.go} internal/dotfilescheck/heavy_build_test.go
  '';

  # Only the test: the binary is the package's to build.
  buildPhase = ''
    runHook preBuild
    runHook postBuild
  '';
  checkPhase = ''
    runHook preCheck
    go test -count=1 -v ./internal/dotfilescheck
    runHook postCheck
  '';
  installPhase = ''
    touch $out
  '';
})
