# Homelab Services Index
# All .nix files in this directory and subdirectories are automatically imported
# Each module provides a cg.<name>.enable option
{ lib, ... }:
let
  helpers = import ../../lib { inherit lib; };
in
{
  imports = helpers.importDirRecursive ./.;
}
