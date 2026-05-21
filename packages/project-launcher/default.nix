# project-launcher: a Hyprland-aware project workspace manager.
#
# Discovers projects under configured directories, opens a rofi picker, and
# either creates a new named Hyprland workspace (pre-seeded with nvim and a
# terminal) or switches to an existing one. Also streams JSON updates to
# waybar so the bar can show the active project.
#
# Runtime dependencies (rofi, hyprctl, ghostty, nvim) are NOT declared as
# buildInputs because they are invoked by name from the user's environment
# rather than wrapped paths. This keeps the binary portable across hosts
# that may have slightly different versions of those tools.
{
  lib,
  buildGoModule,
}:

buildGoModule {
  pname = "project-launcher";
  version = "0.1.0";

  src = ./.;

  # No external Go dependencies — stdlib only.
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
