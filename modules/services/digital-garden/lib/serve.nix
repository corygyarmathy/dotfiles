# How a generated site is served, shared by the NixOS service and the local
# preview so that a routing fix lands in both.
#
# This was lib/site.nix, which also held the Quartz rendering pass; that half
# left with Quartz, and rendering now lives in lib/hugo.nix. Serving stays
# separate from it because it is a property of the output tree, not of the
# program that produced the tree — which is exactly what let the two generators
# be compared under identical routing while the choice was open.
{ lib }:
{
  # Serving config for a generated site rooted at `root`.
  #
  # The try_files line is not boilerplate. Hugo emits `<slug>/index.html` and
  # links to `<slug>`, so getting this wrong either 404s every internal link or
  # spends a redirect on each one.
  caddyConfig = root: ''
    root * ${root}
    encode gzip zstd
    # The index INSIDE a directory is tried before the directory itself,
    # because file_server answers a request for a directory with a 308 to its
    # trailing-slash form. Naming index.html directly serves the page on the
    # first request instead, which is what turns every internal link from two
    # round trips into one.
    #
    # After that: the literal path, for assets; then the same slug with a .html
    # extension, which is the shape a generator that emits `<slug>.html` rather
    # than `<slug>/index.html` produces. Keeping that third case costs nothing
    # and means the served URLs do not depend on which generator built the
    # tree.
    try_files {path}/index.html {path} {path}.html
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
