# The build gate for the palette's generated files.
#
# Item 5 of docs/plans/desktop-design.md struck a deal: the colour half of the
# waybar and rofi configuration is generated from lib/kanagawa-wave.nix, and a
# copy is *also* checked in under configs/ so that those configurations keep
# working on a machine that has never heard of Nix. A deal like that is only
# worth having if something notices when the two halves stop agreeing.
#
# This is that something, and it is the same shape as the command check item 1
# added: it runs at build time and its output is what gets deployed, so there
# is no way to ship a colour file the check has not passed on. A hand-edited
# theme fails `nixos-rebuild switch` on the laptop and fails the host build in
# CI, rather than drifting until somebody notices the bar and the launcher no
# longer match.
{ pkgs }:
{
  # `files` is a list of { path, deployed, expected }:
  #   path     - where the file lives in the working tree, for the error message
  #   deployed - the checked-in copy, as it will be installed
  #   expected - what lib/kanagawa-wave.nix generates for it
  #
  # Returns shell to run inside a derivation.
  assertGenerated =
    files:
    builtins.concatStringsSep "\n" (
      map (file: ''
        if ! diff -u --label ${file.path} --label '(generated)' \
             ${file.deployed} ${pkgs.writeText (baseNameOf file.path) file.expected}
        then
          echo
          echo "${file.path} is not what lib/kanagawa-wave.nix generates."
          echo
          echo "That file is generated and checked in; the copy is what a machine"
          echo "without Nix gets. Change the palette rather than the copy, then:"
          echo
          echo "    nix run .#write-palette"
          echo
          exit 1
        fi
      '') files
    );
}
