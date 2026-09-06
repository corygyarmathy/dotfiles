# project-launcher: a Hyprland-aware project workspace manager.
#
# Discovers projects under configured directories, opens a rofi picker, and
# either creates a new named Hyprland workspace (pre-seeded with nvim and a
# terminal) or switches to an existing one. Also streams JSON updates to
# waybar so the bar can show the active project.
#
# Runtime dependencies (rofi-menu, hyprctl, ghostty, nvim) are NOT declared as
# buildInputs because they are invoked by name from the user's environment
# rather than wrapped paths. This keeps the binary portable across hosts
# that may have slightly different versions of those tools.
#
# The picker calls `rofi-menu` rather than `rofi`: item 7 of
# docs/plans/desktop-design.md makes one wrapper the way every list on this
# desktop is presented, so that they cannot drift into looking like four
# different menus. modules/home/desktop/rofi.nix installs it.
{
  lib,
  buildGoModule,
}:

buildGoModule {
  pname = "project-launcher";
  version = "0.1.0";

  src = ./.;

  # No external Go dependencies — stdlib only.
  #
  # This is load-bearing for .github/dependabot.yml, which has a dormant `gomod`
  # entry pointed here. The moment this program gains its first dependency,
  # vendorHash stops being null, and a Dependabot go.mod/go.sum bump will produce
  # a PR that looks clean and fails `nix build` — it has no idea the hash exists.
  # The gate catches it, so it cannot land broken, but the fix is to give this
  # package a `passthru.updateScript` that bumps the module and regenerates the
  # hash, and let package-update.yml own it instead of Dependabot.
  vendorHash = null;

  # Tests are not included yet; this keeps the build path simple.
  doCheck = false;

  meta = {
    description = "Hyprland project workspace launcher with rofi and waybar integration";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "project-launcher";
  };
}
