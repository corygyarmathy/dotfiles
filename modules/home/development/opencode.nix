# OpenCode AI coding agent
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.opencode;
in
{
  options.cg.home.opencode.enable = lib.mkEnableOption "OpenCode AI coding agent";

  config = lib.mkIf cfg.enable {
    # Source portable config files
    # These files can be used standalone on non-NixOS systems
    # force = true replaces the pre-existing unmanaged files opencode writes
    # into ~/.config/opencode on first launch (e.g. a bare $schema stub).
    xdg.configFile."opencode/opencode.jsonc" = {
      source = ../../../configs/opencode/opencode.jsonc;
      force = true;
    };
    xdg.configFile."opencode/tui.jsonc" = {
      source = ../../../configs/opencode/tui.jsonc;
      force = true;
    };

    # opencode only runs LSP servers that are already installed (all provided
    # by the nvim module's home.packages). Never let it npm/GitHub-download its
    # own copies: the fleet ships pinned nixpkgs binaries, reproducible on
    # every redeploy.
    home.sessionVariables.OPENCODE_DISABLE_LSP_DOWNLOAD = "true";

    home.packages = [ pkgs.opencode ];
  };
}
