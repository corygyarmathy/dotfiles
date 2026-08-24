# Shared site machinery for the digital garden.
#
# Everything here is used by BOTH the NixOS service (digital-garden.nix) and the
# local preview (preview.nix), and that is the whole point of the file existing.
# The preview is only worth having if it renders and serves a page the same way
# production does; the moment the two drift, tuning CSS against the preview is
# tuning against a lie. So the rendering pass and the Caddy config live here
# once, and neither consumer is allowed its own copy.
#
# What is deliberately NOT here: obtaining the vault, the skip gates, the
# publish filter, and the atomic swap. Those are the service's job. This file
# answers exactly two questions — "given a tree of filtered markdown, how is the
# site generated?" and "how is a generated site served?".
{
  pkgs,
  lib,
  quartz,
}:
let
  qpkg = "${quartz}/lib/node_modules/@jackyzha0/quartz";
  # name -> /nix/store/... for every vendored plugin. Written to disk so the
  # config rewriter can turn `github:quartz-community/x` into a local absolute
  # path, which Quartz symlinks instead of cloning. See packages/quartz.
  pluginMap = pkgs.writeText "quartz-plugin-map.json" (builtins.toJSON quartz.passthru.pluginPaths);

  # Rewrites upstream's default config rather than pinning a full copy of it,
  # so a Quartz upgrade that adds or renames plugins does not silently produce
  # a broken site. Only the values we care about are forced.
  mkConfig =
    pkgs.writers.writePython3 "quartz-mkconfig" { libraries = [ pkgs.python3Packages.pyyaml ]; }
      ''
        import json
        import sys

        import yaml

        src, plugin_map_path, dest = sys.argv[1:4]
        base_url, title, disabled_csv, footer_links_json, enabled_out = sys.argv[4:9]
        plugin_options_json, plugin_layout_json, layout_config_json = sys.argv[9:12]
        disabled = {n for n in disabled_csv.split(",") if n}
        footer_links = json.loads(footer_links_json)
        plugin_options = json.loads(plugin_options_json)
        plugin_layout = json.loads(plugin_layout_json)
        layout_config = json.loads(layout_config_json)


        def slot(entry, key):
            # These keys are absent for many entries and can be an explicit null,
            # neither of which .setdefault alone survives.
            if not isinstance(entry.get(key), dict):
                entry[key] = {}
            return entry[key]


        def deep_merge(base, over):
            # byPageType is a map of maps: assigning content.template must not
            # take folder's settings with it.
            for key, value in over.items():
                if isinstance(value, dict) and isinstance(base.get(key), dict):
                    deep_merge(base[key], value)
                else:
                    base[key] = value
            return base


        with open(src) as fh:
            conf = yaml.safe_load(fh)
        with open(plugin_map_path) as fh:
            plugins = json.load(fh)

        c = conf.setdefault("configuration", {})
        c["pageTitle"] = title
        c["baseUrl"] = base_url
        # No third-party analytics, and no Google Fonts / CDN fetches from a page
        # that is meant to be self-hosted.
        c["analytics"] = None
        theme = c.setdefault("theme", {})
        theme["fontOrigin"] = "local"
        theme["cdnCaching"] = False
        # publish-filter.py derives a `published:` date for every note from its
        # ledger, so that is the date worth showing. Upstream defaults to
        # "modified", which here would just be the last time the note was
        # touched at all.
        c["defaultDateType"] = "published"

        for entry in conf.get("plugins", []):
            source = entry.get("source", "")
            name = source.rsplit("/", 1)[-1]
            if name in plugins:
                entry["source"] = plugins[name]
            elif source.startswith("github:"):
                # Not vendored: leaving it would make Quartz try to clone at build
                # time, which fails closed here rather than reaching the network.
                entry["enabled"] = False
            # A plugin whose own runtime deps are missing does not degrade — it
            # leaves an undefined in the component list and kills the whole build.
            if name in disabled:
                entry["enabled"] = False
            # Defence in depth only — publish-filter.py is the real boundary.
            elif name == "explicit-publish":
                entry["enabled"] = True
            # Upstream ships the Quartz project's own GitHub and Discord as footer
            # links, which would otherwise appear on this site.
            if name == "footer":
                slot(entry, "options")["links"] = footer_links
            # Applied BEFORE the caller's options, so it is only a default. The
            # site-level configuration.defaultDateType above cannot do this job:
            # this plugin writes defaultDateType onto every file, and the
            # per-file value is what content-meta actually reads.
            if name == "created-modified-date":
                slot(entry, "options")["defaultDateType"] = "published"

            if name in plugin_options:
                slot(entry, "options").update(plugin_options[name])

            # Applied AFTER, because it is not negotiable: the vendored plugin
            # has its git support stubbed out, and asking for it throws at build
            # time. See packages/quartz/default.nix.
            if name == "created-modified-date":
                slot(entry, "options")["priority"] = ["frontmatter", "filesystem"]

            # `layout` is a sibling of `options`, not part of it: it is where a
            # component's position on the page is decided.
            if name in plugin_layout:
                slot(entry, "layout").update(plugin_layout[name])

        deep_merge(conf.setdefault("layout", {}), layout_config)

        # Only the enabled plugins get linked into .quartz/plugins. Everything
        # placed there is pulled into the esbuild pass whether or not it is
        # enabled, so linking the lot means compiling ~10 unused plugins, wading
        # through their warnings in the journal, and bundling third-party code the
        # site never asked for.
        enabled = {
            name: path
            for name, path in plugins.items()
            if any(
                entry.get("source") == path and entry.get("enabled")
                for entry in conf.get("plugins", [])
            )
        }
        with open(enabled_out, "w") as fh:
            json.dump(enabled, fh)

        with open(dest, "w") as fh:
            yaml.safe_dump(conf, fh, sort_keys=False)
      '';

in
{
  # Serving config for a generated site rooted at `root`, shared by the service
  # and the preview so that a routing fix lands in both. The try_files line in
  # particular is not boilerplate: Quartz emits `<slug>.html` but links to
  # `<slug>`, so getting this wrong 404s every internal link on the site while
  # the homepage looks perfectly fine.
  caddyConfig = root: ''
    root * ${root}
    encode gzip zstd
    # The index INSIDE a directory is tried before the directory itself,
    # because file_server answers a request for a directory with a 308 to its
    # trailing-slash form. Naming index.html directly serves the page on the
    # first request instead, which is what turns every internal link from two
    # round trips into one.
    #
    # After that: the literal path, for assets; then the extension the page was
    # actually written as, for a generator that emits `<slug>.html` rather than
    # `<slug>/index.html`. Both shapes are served without a redirect, so the
    # URLs do not depend on which generator produced the tree.
    try_files {path}/index.html {path} {path}.html
    file_server
    # Quartz also generates a styled 404 page; without this Caddy answers with
    # its own empty one.
    handle_errors {
      rewrite * /404.html
      file_server
    }
    header {
      X-Content-Type-Options "nosniff"
      Referrer-Policy "strict-origin-when-cross-origin"
    }
  '';

  # `digital-garden-render <content-dir> <output-dir> [stylesheet]`
  #
  # Generates a site from an already-filtered markdown tree. The stylesheet is
  # an argument rather than a baked store path so the preview can point it at
  # the working tree and iterate on CSS without a Nix evaluation between each
  # look; the service passes the store path and gets today's behaviour.
  mkRenderer =
    {
      baseUrl,
      siteTitle,
      styleSheet,
      footerLinks ? { },
      disabledPlugins ? [ ],
      pluginOptions ? { },
      pluginLayout ? { },
      layoutConfig ? { },
    }:
    pkgs.writeShellApplication {
      name = "digital-garden-render";
      runtimeInputs = [
        pkgs.nodejs_22
        pkgs.python3
        # The build leans on find/grep/coreutils. The service unit this runs
        # under is hardened enough that relying on the ambient environment for
        # its correctness is asking for trouble.
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
      ];
      text = ''
        if [ $# -lt 2 ] || [ $# -gt 3 ]; then
          echo "usage: digital-garden-render <content-dir> <output-dir> [stylesheet]" >&2
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

        # Quartz is designed to run in-tree: it reads ./package.json from CWD, and
        # quartz/components/Head.tsx imports "../../.quartz/plugins" relative to
        # its own source file. Symlinking the package in resolves that path back
        # into the read-only store, so the tree has to be a writable COPY and the
        # CLI has to be invoked from that copy — not via ${quartz}/bin/quartz,
        # which would resolve its transpile cache into the store and fail.
        work=$(mktemp -d --tmpdir digital-garden-render.XXXXXX)
        trap 'rm -rf "$work"' EXIT
        # Everything EXCEPT node_modules, which is symlinked back in below. cp -r
        # follows the store symlinks inside it and expands ~19MB of tree into
        # ~2.3GB, only for the next line to delete it again.
        ( cd ${qpkg} && find . -mindepth 1 -maxdepth 1 ! -name node_modules \
            -exec cp -r --no-preserve=mode,ownership {} "$work"/ \; )
        ln -s ${qpkg}/node_modules "$work/node_modules"
        cd "$work"

        ${mkConfig} quartz.config.default.yaml ${pluginMap} quartz.config.yaml \
          "${baseUrl}" "${siteTitle}" \
          "${lib.concatStringsSep "," disabledPlugins}" \
          ${lib.escapeShellArg (builtins.toJSON footerLinks)} \
          "$work/enabled-plugins.json" \
          ${lib.escapeShellArg (builtins.toJSON pluginOptions)} \
          ${lib.escapeShellArg (builtins.toJSON pluginLayout)} \
          ${lib.escapeShellArg (builtins.toJSON layoutConfig)}

        # Quartz compiles quartz/styles/custom.scss into its stylesheet last, so
        # these rules win over base.scss at equal specificity without !important.
        #
        # APPEND, never overwrite. That file is not the empty hook it looks like:
        # it carries the `@use "./base.scss"` that pulls the ENTIRE base
        # stylesheet into the build. Replacing it drops every base rule — fonts,
        # colours, the flex helpers the layout depends on — and the site still
        # builds, still deploys, and renders as nearly unstyled prose. Fail here
        # if that import ever moves, rather than discovering it in a browser.
        grep -q '@use "./base.scss"' quartz/styles/custom.scss
        cat "$css" >> quartz/styles/custom.scss

        # Plugins are vendored from npm (they ship dist/, which the source repos
        # do not — and regeneratePluginIndex skips anything without
        # dist/index.d.ts, yielding a featureless site). Only the enabled ones are
        # linked, plus whatever core Quartz imports unconditionally; see below and
        # the note in mkConfig.
        mkdir -p .quartz/plugins
        python3 - ${pluginMap} <<'EOF'
        import json, os, sys

        all_plugins = json.load(open(sys.argv[1]))
        linked = json.load(open("enabled-plugins.json"))

        # quartz/components/Head.tsx imports CustomOgImagesEmitterName from
        # ../../.quartz/plugins at the top level, whether or not og-image is
        # switched on — so the plugin must be present for the index to export the
        # symbol, even though it stays disabled (it needs sharp at runtime).
        # Being in the index costs nothing: Quartz instantiates only what
        # quartz.config.yaml enables. Without this, esbuild fails the whole build
        # with "No matching export in .quartz/plugins/index.ts".
        for name in ["og-image"]:
            linked.setdefault(name, all_plugins[name])

        for name, path in linked.items():
            dest = os.path.join(".quartz", "plugins", name)
            if os.path.lexists(dest):
                os.unlink(dest)
            os.symlink(path, dest)

        # `plugin install` below is run ONLY to regenerate index.ts, but it also
        # clones every lockfile entry missing from disk — and this service has
        # network, so it really does fetch third-party plugins from GitHub and npm
        # at build time, which is exactly what vendoring them was meant to stop.
        # Declaring the linked set as `local` entries resolving to the symlink
        # targets makes it verify each one and move on: no network, no npm.
        json.dump(
            {
                "version": "1.0.0",
                "plugins": {
                    n: {"commit": "local", "resolved": p} for n, p in sorted(linked.items())
                },
            },
            open("quartz.lock.json", "w"),
            indent=2,
        )
        print(f"linked {len(linked)} plugins")
        EOF

        # Regenerates .quartz/plugins/index.ts from what is on disk.
        node ./quartz/bootstrap-cli.mjs plugin install

        # A plugin missing from the index surfaces only as an opaque esbuild error
        # about Head.tsx, so fail here instead, where the cause is obvious.
        grep -q CustomOgImagesEmitterName .quartz/plugins/index.ts

        node ./quartz/bootstrap-cli.mjs build \
          -d "$content" -o "$outdir"

        # Serve the browser-side libraries ourselves rather than letting the page
        # pull them from cdnjs/jsdelivr. The quartz package rewrites the imports
        # to these paths; mermaid resolves its chunks relative to the bundle, so
        # that directory has to come along too.
        mkdir -p "$outdir/static/mermaid" \
                 "$outdir/static/vendor"
        cp ${quartz.passthru.mermaidDist}/dist/mermaid.esm.min.mjs \
          "$outdir/static/mermaid/"
        cp -r ${quartz.passthru.mermaidDist}/dist/chunks \
          "$outdir/static/mermaid/"
        cp ${quartz.passthru.vendorDir}/* "$outdir/static/vendor/"
        chmod -R u+w "$outdir/static"

      '';
    };
}
