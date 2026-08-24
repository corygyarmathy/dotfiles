# How a generated site is served, shared by the NixOS service and the local
# preview so that a routing fix lands in both.
#
# Kept apart from lib/hugo.nix on purpose: serving is a property of the output
# tree, not of the program that produced it. A site that has been rendered to
# HTML has no remaining opinion about who rendered it, and routing that has to
# be reasoned about alongside a generator's internals is routing nobody can
# check.
{ lib }:
{
  # Serving config for a generated site rooted at `root`.
  #
  # The try_files line is not boilerplate. Hugo emits `<slug>/index.html`, and
  # getting this wrong spends a redirect on requests that should be answered
  # directly.
  caddyConfig = root: ''
    root * ${root}
    encode gzip zstd
    # The index INSIDE a directory is tried before the directory itself,
    # because file_server answers a request for a bare directory with a 308 to
    # its trailing-slash form. Naming index.html directly serves the page on
    # the first request instead.
    #
    # The site's own links carry the slash (publish-filter.py writes them that
    # way, to match what Hugo puts in rel=canonical), so this is not what makes
    # the common case fast — it is what keeps the SLASHLESS form a first-class
    # address rather than a redirect. Old links and typed URLs take that form,
    # and they are the ones with nothing to fall back on.
    #
    # Then the literal path, which is how every asset — the stylesheet, the
    # feed, the search bundle — is answered.
    try_files {path}/index.html {path}
    file_server
    # Hugo generates a styled 404 page; without this Caddy answers with its own
    # empty one.
    handle_errors {
      rewrite * /404.html
      file_server
    }
    header {
      X-Content-Type-Options "nosniff"
      Referrer-Policy "strict-origin-when-cross-origin"
    }
  '';
}
