# How the digital garden is generated:
#
#   digital-garden-render-hugo <content-dir> <output-dir> [stylesheet]
#
# The property to preserve here is that the whole toolchain is two static
# binaries from nixpkgs — Hugo in Go, Pagefind in Rust — both riding
# flake.lock, neither fetching anything at build time or in the reader's
# browser. A generator that resolves plugins over the network at build time
# fails in the one way a CI gate cannot see: the build succeeds and the site is
# quietly missing features. Anything added below should be weighed against
# that, not against convenience. See docs/adr/ for how this was arrived at.
#
# What keeps this file short is that publish-filter.py already owns the hard
# parts. The staging tree's links carry finished URLs and its files are named
# what they will be served as, so this renderer does not have to resolve a
# wikilink or decide what a page is called. It supplies a layout and a
# stylesheet and gets out of the way. Everything Hugo-specific is in this
# file and lib/hugo/.
#
# Two Obsidian-isms DO reach the renderer, both deliberately, because Hugo's
# parser understands them natively and any CommonMark renderer degrades them
# gracefully: callouts (> [!type], rendered by _markup/render-blockquote.html)
# and $...$ maths (captured by the passthrough extension and rendered to HTML
# at build time by _markup/render-passthrough.html). KaTeX's stylesheet and
# fonts are vendored from nixpkgs below, so a page with equations still needs
# no JavaScript and nothing fetched from anyone else's server.
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
      siteDescription ? "",
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
        # `date` last, so a note that was never edited reports its publication
        # date as its last change rather than no date at all. Without it the
        # feed's lastBuildDate and the sitemap's <lastmod> were empty, because
        # publish-filter.py only writes `modified` when it differs from
        # `published`. The dateline and the social card both compare the two
        # and stay quiet when they are equal, so nothing starts claiming a note
        # was updated on the day it was published.
        lastmod = ['modified', 'lastmod', 'date']

        # Chroma writes its colours inline by default, which hard-codes one
        # theme into the markup: every fenced block shipped Monokai's #272822
        # ground and #f8f8f2 text regardless of what the reader had chosen.
        # That was invisible while the site's dark theme was near-black, and
        # became a black box in the middle of a warm page the moment the light
        # theme stopped being white. Classes instead, so the stylesheet colours
        # code the same way it colours everything else - and so the theme
        # toggle reaches it, which inline styles never allowed.
        [markup.highlight]
        noClasses = false

        [markup.goldmark.renderer]
        # The vault contains no raw HTML, only autolinks — which are CommonMark
        # and unaffected by this. Left off so a note cannot put markup, or a
        # script, onto a public page.
        unsafe = false

        [markup.goldmark.extensions.extras.mark]
        # Obsidian's ==highlights==. Off by default; without this the markers
        # render as literal text.
        enable = true

        [markup.goldmark.extensions.passthrough]
        # Captures $...$ and $$...$$ verbatim so _markup/render-passthrough.html
        # can hand them to Hugo's embedded KaTeX instance. The delimiters are
        # Obsidian's, which is the point: a note reads the same in both places.
        # The cost of the inline one is Obsidian's too — a literal $ in prose
        # between two $s is maths to both — so this changes nothing about how
        # notes are written.
        enable = true
        [markup.goldmark.extensions.passthrough.delimiters]
        block = [['$$', '$$']]
        inline = [['$', '$']]

        [params]
        description = ${builtins.toJSON siteDescription}
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
        # The theme's own assets, and then the stylesheet over the top of them.
        # The stylesheet is the one asset that arrives as an argument, because
        # garden-preview hands in the working-tree copy so that editing it
        # re-renders with no Nix evaluation in the loop; everything else here
        # (the tab icon) has no reason to be swappable and lives in the theme.
        # Copying the directory first and the argument second is what keeps
        # both true, and means the next asset needs no change to this file.
        mkdir -p "$work/assets"
        cp -r ${theme}/assets/. "$work/assets/"
        # Store paths copy out read-only, and the theme's assets already hold a
        # main.css - so the overlay below is an overwrite of a file with no
        # write bit on it. Same reason the static and content trees are chmod-ed
        # after their copies rather than at the end.
        chmod -R u+w "$work/assets"
        cp "$css" "$work/assets/main.css"
        cp ${config} "$work/hugo.toml"
        chmod -R u+w "$work"

        # KaTeX's stylesheet and fonts, vendored from nixpkgs and served as
        # ordinary static files. Pages with equations render maths to HTML at
        # build time (see _markup/render-passthrough.html), so this is ALL the
        # reader's browser ever sees of KaTeX - no script. baseof.html links
        # the stylesheet only on pages that used maths, so a reading page
        # never pays for it.
        mkdir -p "$work/static/katex"
        cp ${pkgs.katex}/lib/node_modules/katex/dist/katex.min.css "$work/static/katex/"
        cp -r ${pkgs.katex}/lib/node_modules/katex/dist/fonts "$work/static/katex/fonts"

        # Store paths copy out read-only, and the exit trap's rm -rf cannot
        # remove a read-only directory's contents.
        chmod -R u+w "$work/static"

        mkdir -p "$work/content"
        cp -r "$content/." "$work/content/"
        chmod -R u+w "$work/content"
        # Hugo's home page comes from `_index.md`; a plain `index.md` at the
        # content root would make the whole site one leaf bundle instead. The
        # filter has no business knowing that, so the rename happens here.
        if [ -f "$work/content/index.md" ]; then
          mv "$work/content/index.md" "$work/content/_index.md"
        fi

        # A generated /notes/ page lists everything published, so that nothing
        # on the site is reachable only by search or by a backlink — fourteen
        # of nineteen notes once were, and the landing page is deliberately
        # still the hand-written table of contents. Chrome, like the 404 and
        # the feed, so it is born here rather than in the vault or the staging
        # tree: the staging tree is exactly the published set. Rendered by
        # layouts/_default/list.html.
        mkdir -p "$work/content/notes"
        cat > "$work/content/notes/_index.md" <<'EOF'
        ---
        title: All notes
        description: Every published note, newest first.
        ---

        Every note published here, newest first.

        EOF

        # Not --quiet: this runs inside a oneshot service whose journal is the
        # only place a failure surfaces. A quiet hugo turned "KaTeX could not
        # render this expression" into two silent seconds and exit 1.
        hugo --source "$work" --destination "$outdir"

        # Search index, built from the rendered HTML rather than from the
        # markdown, so what is searchable is exactly what is readable. Runs
        # here rather than as a separate step because a site whose index does
        # not match its pages is worse than one with no search at all.
        pagefind --site "$outdir"
      '';
    };
}
