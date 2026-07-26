# psql client configuration
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.psql;
in
{
  options.cg.home.psql.enable = lib.mkEnableOption "psql client configuration";

  config = lib.mkIf cfg.enable {
    # psql only reads ~/.psqlrc - it has no XDG support - so this is a
    # home.file rather than an xdg.configFile.
    #
    # Note: vim-dadbod runs `psql` without -X, so these settings also apply to
    # query results in :DBUI buffers. Its drawer introspection uses
    # --no-psqlrc, so the table list is unaffected.
    home.file.".psqlrc".text = ''
      -- Managed by Home Manager. Comments are SQL-style (--).

      -- Suppress the echo of each setting below while this file is read.
      \set QUIET 1

      -- Row-per-field layout, but only when a row is too wide for the terminal.
      -- The single biggest readability win: wide tables and JSONB documents stop
      -- wrapping into unreadable soup, narrow results keep the compact table.
      \x auto

      -- Distinguish NULL from the empty string, which print identically by default.
      \pset null '(null)'

      -- Report duration of every query.
      \timing on

      -- In an interactive transaction, roll back only the statement that errored
      -- instead of aborting the whole transaction on a typo.
      \set ON_ERROR_ROLLBACK interactive

      -- Tab-complete keywords as SELECT, not select.
      \set COMP_KEYWORD_CASE upper

      -- Per-database history, so recalled queries match the database you are in.
      -- The parent directory is created below; psql will not create it itself.
      \set HISTFILE ~/.local/state/psql/history-:DBNAME

      -- less flags: -S chop long lines (scroll sideways) rather than wrap,
      -- -F skip the pager when output fits one screen, -X no terminal init,
      -- -R pass through colour.
      \setenv PAGER 'less -SFXR'

      \unset QUIET
    '';

    # psql writes HISTFILE but will not create its parent directory.
    home.file.".local/state/psql/.keep".text = "# Managed by Home Manager";
  };
}
