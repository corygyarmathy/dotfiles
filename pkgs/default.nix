# The purpose of this file is to list all home-manager modules in one place
# This is then imported in the relevant systems home-manager file
# Each module is individually enabled as required for them to apply
{ pkgs, lib, ... }:
{
  imports = [
    ./nvim
    ./starship
    ./waybar
    ./rofi
  ];
}
