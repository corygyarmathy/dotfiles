# How the digital garden is generated:
#
#   digital-garden-render-hugo <content-dir> <output-dir> [stylesheet]
#
# Why Hugo. The site was built with Quartz until 2026-08-24, which cost 562
# lines of Nix and a tree of ~42 hash-pinned npm plugins, because Quartz v5
# resolves its own plugins by cloning them at build time. The decisive problem
# was not the size of that but that it could not be updated: a wrong bump
# produces a build that SUCCEEDS and a site that is silently featureless, so
# the version was pinned and stayed pinned. Hugo is one Go binary in nixpkgs
# and Pagefind is one Rust binary; both ride flake.lock, and neither fetches
# anything at build time or in the reader's browser.
#
# What made this cheap is that publish-filter.py already owns the hard parts.
# The staging tree is plain CommonMark whose links carry finished URLs, so this
# renderer does not have to understand Obsidian, resolve a wikilink, or decide
# what a page is called. It supplies a layout and a stylesheet and gets out of
# the way. Everything Hugo-specific is in this file and lib/hugo/.
{
  pkgs,
  lib,
}:
let
  theme = ./hugo;
in
{
  mkRenderer =
    {
      baseUrl,
      siteTitle,
      styleSheet,
      footerLinks ? { },
      locale ? "en-au",
    }:
    let
      config = pkgs.writeText "hugo.toml" ''
        baseURL = 'https://${baseUrl}/'
        locale = '${locale}'
        title = ${builtins.toJSON siteTitle}
        enableRobotsTXT = true

        # publish-filter.py derives dates from its ledger as bare local dates,
        # and Hugo reads a bare date as midnight UTC. Anywhere behind UTC that
        # puts a note published "today" up to a day in the future, and Hugo
        # omits future content by default — which silently cost 15 of 16 pages
        # the first time this was built. There is no scheduled publishing here:
        # a date is metadata about a note, not an embargo on it.
        buildFuture = true

        # Nothing here is organised by tag, and an empty taxonomy listing is
        # just another URL that has to be explained.
        disableKinds = ['taxonomy', 'term']

        [frontmatter]
        date = ['published', 'date']
        lastmod = ['modified', 'lastmod']

        [markup.goldmark.renderer]
        # The vault contains no raw HTML, only autolinks — which are CommonMark
        # and unaffected by this. Left off so a note cannot put markup, or a
        # script, onto a public page.
        unsafe = false

        [params]
        footerLinks = [
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: url: "  { name = ${builtins.toJSON name}, url = ${builtins.toJSON url} },"
          ) footerLinks
        )}
        ]
      '';
    in
    pkgs.writeShellApplication {
      name = "digital-garden-render-hugo";
      runtimeInputs = [
        pkgs.hugo
        pkgs.pagefind
        pkgs.coreutils
      ];
      text = ''
        if [ $# -lt 2 ] || [ $# -gt 3 ]; then
          echo "usage: digital-garden-render-hugo <content-dir> <output-dir> [stylesheet]" >&2
          exit 2
        fi
        content=$(realpath "$1")
        outdir=$2
        css=$(realpath "''${3:-${styleSheet}}")

        if [ ! -d "$content" ]; then
          echo "no such content directory: $content" >&2
          exit 1
        fi
        rm -rf "$outdir"
        mkdir -p "$outdir"
        outdir=$(realpath "$outdir")

        # Hugo wants a site directory. Assembled per run rather than kept,
        # because every input is either in the store or handed in as an
        # argument, so there is nothing here worth preserving between builds.
        work=$(mktemp -d --tmpdir digital-garden-hugo.XXXXXX)
        trap 'rm -rf "$work"' EXIT

        cp -r ${theme}/layouts "$work/layouts"
        mkdir -p "$work/assets"
        cp "$css" "$work/assets/main.css"
        cp ${config} "$work/hugo.toml"
        chmod -R u+w "$work"

        mkdir -p "$work/content"
        cp -r "$content/." "$work/content/"
        chmod -R u+w "$work/content"
        # Hugo's home page comes from `_index.md`; a plain `index.md` at the
        # content root would make the whole site one leaf bundle instead. The
        # filter has no business knowing that, so the rename happens here.
        if [ -f "$work/content/index.md" ]; then
          mv "$work/content/index.md" "$work/content/_index.md"
        fi

        hugo --quiet --source "$work" --destination "$outdir"

        # Search index, built from the rendered HTML rather than from the
        # markdown, so what is searchable is exactly what is readable. Runs
        # here rather than as a separate step because a site whose index does
        # not match its pages is worse than one with no search at all.
        pagefind --site "$outdir" --quiet
      '';
    };
}
