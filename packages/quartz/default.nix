# Quartz - static site generator for Obsidian-style markdown vaults.
#
# Not in nixpkgs. Upstream expects you to fork the repo and build in-tree, so
# this packages the released tarball instead and exposes the `quartz` CLI.
#
# Non-obvious implementation notes:
# - Quartz v5 resolves its ~42 first-party plugins by CLONING them from
#   github:quartz-community/* at build time. That cannot work in the Nix
#   sandbox, and it also means an unpinned supply chain for a public-facing
#   site. Every plugin is instead vendored here as a hash-pinned npm release
#   (plugins.json), and the consumer points each `source:` at a store path.
# - That works because gitLoader.ts treats an ABSOLUTE PATH source as "local"
#   and symlinks it, skipping the clone and the HEAD check entirely. A
#   `github:` source would instead require a real .git dir and network.
# - The plugins come from npm rather than from the git revisions in
#   quartz.lock.json, because regeneratePluginIndex skips any plugin lacking
#   dist/index.d.ts and the GitHub trees ship only src/. Vendoring the repos
#   therefore produces an EMPTY plugin index and a silently featureless site.
#   The npm releases carry prebuilt dist/, so nothing needs compiling.
# - dontNpmBuild: there is no build script; we only want deps installed and the
#   `quartz` bin linked.
#
# Four plugins are unusable here because their own runtime dependencies are
# native and not vendored — created-modified-date (@napi-rs/simple-git), latex
# (@myriaddreamin/rehype-typst), favicon and og-image (both sharp). Quartz does
# not degrade gracefully when a plugin fails to instantiate: it leaves an
# undefined in the component list and the build dies in ComponentResources.
# They are disabled by the consuming module; see
# cg.service.digital-garden.disabledPlugins.
#
# Several plugins also fetch browser-side libraries from a CDN at runtime, which
# would leak every visitor's IP to a third party from a site whose whole point
# is being self-hosted. mermaid, d3 and pixi.js are vendored and the imports
# rewritten to local /static/ paths; the consuming module copies mermaidDist and
# vendorDir into the generated site.
#
# To update: bump version + hash, re-run
#   nix run nixpkgs#prefetch-npm-deps -- package-lock.json
# and regenerate plugins.json against the npm registry.
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  fetchurl,
  nodejs_22,
  runCommand,
}:
let
  pluginSpecs = lib.importJSON ./plugins.json;

  # Upstream's package-lock declares these two as git+ssh dependencies.
  # prefetch-npm-deps skips git specs silently, so npm ci leaves them out and
  # every plugin then fails to resolve "@quartz-community/utils" at bundle time.
  # Both are also published to npm with prebuilt dist/, so take them from there
  # and install them by hand below.
  communityDeps = {
    utils = fetchurl {
      url = "https://registry.npmjs.org/@quartz-community/utils/-/utils-0.1.1.tgz";
      hash = "sha256-AX2mz7GU5zVhFYKMUoxx21fls1NaCXXZPV80O28eQhk=";
    };
    types = fetchurl {
      url = "https://registry.npmjs.org/@quartz-community/types/-/types-0.3.0.tgz";
      hash = "sha256-pEQhnO0yTXrOxI5HQyQvlKiTO9Edlh1yU2PDk6VQG0I=";
    };
  };

  # Plugins come from npm, not from the github: sources in quartz.lock.json.
  # regeneratePluginIndex skips any plugin without dist/index.d.ts, and the
  # GitHub trees ship only src/ — so vendoring the repos yields an empty plugin
  # index and a site with no features. The npm releases carry prebuilt dist/,
  # which also means nothing here has to be compiled.
  #
  # The tarball is unpacked into a subdirectory named exactly after the plugin,
  # and it is that inner path which is handed to Quartz. config-loader.ts
  # resolves a local plugin source with `path.basename(source)`, so a bare store
  # path would come out as "<hash>-quartz-plugin-footer-0.1.1" and never match
  # "footer" — which silently leaves layout.footer undefined and kills the build
  # in ComponentResources with an undefined component.
  rawPlugins = lib.mapAttrs (
    name: spec:
    runCommand "quartz-plugin-${name}-${spec.version}" { } ''
      mkdir -p $out/${name}
      tar xzf ${
        fetchurl {
          inherit (spec) url hash;
        }
      } -C $out/${name} --strip-components=1
    ''
  ) pluginSpecs;

  # obsidian-flavored-markdown lazy-imports mermaid straight from cdnjs, so a
  # self-hosted page would still send every visitor's IP to Cloudflare the
  # moment it renders a diagram. Vendor mermaid and rewrite the import to a
  # local path; the consuming module copies mermaidDist into the site output.
  mermaidVersion = "11.4.0";
  mermaidDist = runCommand "mermaid-${mermaidVersion}" { } ''
    mkdir -p $out
    tar xzf ${
      fetchurl {
        url = "https://registry.npmjs.org/mermaid/-/mermaid-${mermaidVersion}.tgz";
        hash = "sha256-JvfV1UmM2ImzL5ETSbN3LVF9mct8Ah9qnK3KDRnyDhI=";
      }
    } -C $out --strip-components=1
  '';

  # The graph plugin pulls d3 and pixi.js from jsdelivr at runtime, for the same
  # reason and with the same consequence as mermaid above.
  vendoredScripts = {
    "d3.min.js" = fetchurl {
      url = "https://cdn.jsdelivr.net/npm/d3@7.9.0/dist/d3.min.js";
      hash = "sha256-8glLv2FBs1lyLE/kVOtsSw8OQswQzHr5IfwVj864ZTk=";
    };
    "pixi.js" = fetchurl {
      url = "https://cdn.jsdelivr.net/npm/pixi.js@8.19.0/dist/pixi.js";
      hash = "sha256-mJ38/Ivi3JLW+w51B3aJ2AlWBd379eOApGDIvL0bscw=";
    };
  };

  vendorDir = runCommand "quartz-vendor-scripts" { } (
    "mkdir -p $out\n"
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: file: "cp ${file} $out/${name}") vendoredScripts
    )
  );

  # These URLs appear in more than one bundle within a plugin (entry point and
  # dist/components/), so rewrite every .js and assert afterwards that no CDN
  # reference survived — a silent miss would put the leak straight back.
  localiseCdn =
    {
      name,
      plugin,
      substitutions,
    }:
    runCommand "quartz-plugin-${name}-local-deps" { } ''
      cp -r ${plugin} $out
      chmod -R u+w $out
      find $out -name '*.js' -type f -print0 | while IFS= read -r -d ''' f; do
        ${lib.concatStringsSep "\n        " (
          lib.mapAttrsToList (from: to: ''substituteInPlace "$f" --replace-quiet "${from}" "${to}"'') substitutions
        )}
      done
      if grep -rl --include='*.js' -E 'cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com' $out; then
        echo "ERROR: ${name} still fetches from a CDN after rewriting" >&2
        exit 1
      fi
    '';

  plugins = rawPlugins // {
    obsidian-flavored-markdown = localiseCdn {
      name = "obsidian-flavored-markdown";
      plugin = rawPlugins.obsidian-flavored-markdown;
      substitutions = {
        "https://cdnjs.cloudflare.com/ajax/libs/mermaid/${mermaidVersion}/mermaid.esm.min.mjs" =
          "/static/mermaid/mermaid.esm.min.mjs";
      };
    };

    graph = localiseCdn {
      name = "graph";
      plugin = rawPlugins.graph;
      substitutions = {
        "https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js" = "/static/vendor/d3.min.js";
        "https://cdn.jsdelivr.net/npm/pixi.js@8/dist/pixi.js" = "/static/vendor/pixi.js";
      };
    };
  };

  quartz = buildNpmPackage rec {
    pname = "quartz";
    version = "5.0.0";

    src = fetchFromGitHub {
      owner = "jackyzha0";
      repo = "quartz";
      rev = "v${version}";
      hash = "sha256-Tv2xwlMDz2mH0OnSHuMybYa/QgGrH81PKJ6B2T0YfS8=";
    };

    npmDepsHash = "sha256-FL1xAgKgpUsg8BF+nmLiMv/PZjUSJW4fcWyaC90NZDM=";

    nodejs = nodejs_22; # package requires node >= 22

    # npm wants to write into its cache dir during install; the fetched deps
    # store path is read-only, so give it a writable copy.
    makeCacheWritable = true;

    # `prebuild` shells out to install-plugins, which clones from GitHub.
    # Plugins are vendored instead, so the lifecycle scripts must not run.
    npmFlags = [ "--ignore-scripts" ];
    dontNpmBuild = true;

    postInstall = ''
      qdir="$out/lib/node_modules/@jackyzha0/quartz"

      # Emitted on every page regardless of whether anything loads from cdnjs.
      # With mermaid vendored locally there is nothing left to preconnect to.
      substituteInPlace "$qdir/quartz/components/Head.tsx" \
        --replace-fail \
          '<link rel="preconnect" href="https://cdnjs.cloudflare.com" crossOrigin="anonymous" />' \
          ""

      mkdir -p "$qdir/node_modules/@quartz-community"
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: tarball: ''
          mkdir -p "$qdir/node_modules/@quartz-community/${name}"
          tar xzf ${tarball} -C "$qdir/node_modules/@quartz-community/${name}" \
            --strip-components=1
        '') communityDeps
      )}
    '';

    passthru = {
      inherit plugins mermaidDist vendorDir;

      # Attrset of plugin name -> store path, for generating quartz.config.yaml.
      pluginPaths = lib.mapAttrs (name: drv: "${drv}/${name}") plugins;

      # Convenience: every vendored plugin under one directory, which is the
      # shape .quartz/plugins/ expects if you'd rather pre-populate the cache
      # than rewrite the config sources.
      pluginDir = runCommand "quartz-plugins" { } (
        "mkdir -p $out\n"
        + lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: drv: "ln -s ${drv}/${name} $out/${name}") plugins
        )
      );
    };

    meta = {
      description = "Static site generator for Obsidian-style markdown vaults";
      homepage = "https://quartz.jzhao.xyz";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
      mainProgram = "quartz";
    };
  };
in
quartz
