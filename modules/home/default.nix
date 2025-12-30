# Home-manager modules index
# All .nix files in this directory and subdirectories are automatically imported
# Each module provides a cg.home.<name>.enable option
{ lib, ... }:
let
  helpers = import ../../lib { inherit lib; };
in
{
  imports = helpers.importDirRecursive ./.;
}
