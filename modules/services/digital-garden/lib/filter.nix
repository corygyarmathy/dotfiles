# The publish filter, as ONE DIRECTORY.
#
# publish-filter.py and bonsai.py are one program in two files, which Nix does
# not hand you for free: `${./publish-filter.py}` puts each file in a store
# path of its own, so the import would not resolve at run time - the two have
# to be assembled into one directory. Named file by file rather than copying
# `${./.}`, so that nothing else in this directory (the whole of lib/, a stray
# __pycache__) is dragged into the store and into the build stamp.
#
# Lives under ./lib, the way sync-health.nix does, so that the consumer which
# runs the filter directly against a fixture (checks/digital-garden-filter.nix)
# imports this same assembly rather than re-assembling a second copy that could
# drift from what the service runs. The module exposes the result as
# cg.service.digital-garden.filter for the same reason the preview reads it
# from there.
{ pkgs }:

pkgs.runCommand "digital-garden-filter" { } ''
  mkdir -p "$out"
  cp ${../publish-filter.py} "$out/publish-filter.py"
  cp ${../bonsai.py} "$out/bonsai.py"
''
