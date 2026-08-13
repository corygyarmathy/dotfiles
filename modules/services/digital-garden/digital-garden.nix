# Digital Garden - publish selected notes from the Obsidian vault as a website
#
# Provides:
# - Periodic build of a public site from the private personal-notes vault
# - Only notes explicitly marked `publish: true` are ever included
# - Static output served by Caddy, exposed like any other service
#
# Architecture:
# - Timer -> oneshot builder. The builder clones/pulls the vault, filters it
#   down to published notes, then runs Quartz over the filtered tree.
# - Serving is plain HTTP on 127.0.0.1:<port>, which lets this slot into
#   cg.service.reverse-proxy.services (TLS + LAN) and
#   cg.service.cloudflare-tunnel.services (public) with no special casing.
#
# ════════════════════════════════════════════════════════════════════════════
# The publish boundary
# ════════════════════════════════════════════════════════════════════════════
# publish-filter.py copies ONLY notes containing a literal `publish: true` into
# a staging tree, and Quartz is pointed at that staging tree — never at the
# vault. An unmarked note is therefore not merely unrendered, it is not present
# on disk for the generator to see, so no plugin misconfiguration or upstream
# default change can expose it. Quartz's own explicit-publish plugin is ALSO
# enabled below, but strictly as defence in depth; the filter is the boundary.
#
# Known residual leak: a published note that writes [[Some Private Note]] in
# prose still renders the words "Some Private Note" (as plain text, not a
# link). Titles you type into published notes are published.
#
# Secrets required in secrets/homelab.yaml:
#   digital-garden/deploy-key: <ssh private key with read access to the vault repo>
#
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.cg.service.digital-garden;

  quartz = self.packages.${pkgs.stdenv.hostPlatform.system}.quartz;
  qpkg = "${quartz}/lib/node_modules/@jackyzha0/quartz";

  stateDir = "/var/lib/digital-garden";

  # name -> /nix/store/... for every vendored plugin. Written to disk so the
  # config rewriter can turn `github:quartz-community/x` into a local absolute
  # path, which Quartz symlinks instead of cloning. See packages/quartz.
  pluginMap = pkgs.writeText "quartz-plugin-map.json" (
    builtins.toJSON quartz.passthru.pluginPaths
  );

  # Rewrites upstream's default config rather than pinning a full copy of it,
  # so a Quartz upgrade that adds or renames plugins does not silently produce
  # a broken site. Only the values we care about are forced.
  mkConfig = pkgs.writers.writePython3 "quartz-mkconfig" { libraries = [ pkgs.python3Packages.pyyaml ]; } ''
    import json
    import sys

    import yaml

    src, plugin_map_path, dest = sys.argv[1:4]
    base_url, title, disabled_csv, footer_links_json, enabled_out = sys.argv[4:9]
    disabled = {n for n in disabled_csv.split(",") if n}
    footer_links = json.loads(footer_links_json)

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
            entry.setdefault("options", {})["links"] = footer_links

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

  buildScript = pkgs.writeShellApplication {
    name = "digital-garden-build";
    runtimeInputs = [
      pkgs.git
      pkgs.openssh
      pkgs.python3
      quartz
      pkgs.nodejs_22
    ];
    text = ''
      set -euo pipefail
      export GIT_SSH_COMMAND="ssh -i ${stateDir}/deploy-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

      # ---- 1. get the vault -------------------------------------------------
      if [ -d "${stateDir}/vault/.git" ]; then
        git -C "${stateDir}/vault" fetch --depth 1 origin "${cfg.branch}"
        git -C "${stateDir}/vault" reset --hard "origin/${cfg.branch}"
        git -C "${stateDir}/vault" clean -fdx
      else
        rm -rf "${stateDir}/vault"
        git clone --depth 1 --branch "${cfg.branch}" "${cfg.vaultRepo}" "${stateDir}/vault"
      fi

      # ---- 2. reduce it to only what is marked publish: true -----------------
      python3 ${./publish-filter.py} "${stateDir}/vault" "${stateDir}/content"

      # ---- 3. build ---------------------------------------------------------
      # Quartz is designed to run in-tree: it reads ./package.json from CWD, and
      # quartz/components/Head.tsx imports "../../.quartz/plugins" relative to
      # its own source file. Symlinking the package in resolves that path back
      # into the read-only store, so the tree has to be a writable COPY and the
      # CLI has to be invoked from that copy — not via ${quartz}/bin/quartz,
      # which would resolve its transpile cache into the store and fail.
      work="${stateDir}/work"
      rm -rf "$work"
      mkdir -p "$work"
      cp -r --no-preserve=mode,ownership ${qpkg}/. "$work"/
      rm -rf "$work/node_modules"
      ln -s ${qpkg}/node_modules "$work/node_modules"
      cd "$work"

      ${mkConfig} quartz.config.default.yaml ${pluginMap} quartz.config.yaml \
        "${cfg.baseUrl}" "${cfg.siteTitle}" \
        "${lib.concatStringsSep "," cfg.disabledPlugins}" \
        ${lib.escapeShellArg (builtins.toJSON cfg.footerLinks)} \
        "$work/enabled-plugins.json"

      # Plugins are vendored from npm (they ship dist/, which the source repos
      # do not — and regeneratePluginIndex skips anything without
      # dist/index.d.ts, yielding a featureless site). Only the enabled ones
      # are linked; see the note in mkConfig.
      mkdir -p .quartz/plugins
      python3 - <<'EOF'
      import json, os
      plugins = json.load(open("enabled-plugins.json"))
      for name, path in plugins.items():
          dest = os.path.join(".quartz", "plugins", name)
          if os.path.lexists(dest):
              os.unlink(dest)
          os.symlink(path, dest)
      print(f"linked {len(plugins)} enabled plugins")
      EOF

      # Regenerates .quartz/plugins/index.ts. It also tries to `git fetch` each
      # plugin and reports "42 failed"; that is cosmetic — the plugins are
      # already present, and the index is rebuilt after the update loop either
      # way. Hence the `|| true`.
      node ./quartz/bootstrap-cli.mjs plugin install || true

      node ./quartz/bootstrap-cli.mjs build \
        -d "${stateDir}/content" -o "${stateDir}/public.new"

      # Serve the browser-side libraries ourselves rather than letting the page
      # pull them from cdnjs/jsdelivr. The quartz package rewrites the imports
      # to these paths; mermaid resolves its chunks relative to the bundle, so
      # that directory has to come along too.
      mkdir -p "${stateDir}/public.new/static/mermaid" \
               "${stateDir}/public.new/static/vendor"
      cp ${quartz.passthru.mermaidDist}/dist/mermaid.esm.min.mjs \
        "${stateDir}/public.new/static/mermaid/"
      cp -r ${quartz.passthru.mermaidDist}/dist/chunks \
        "${stateDir}/public.new/static/mermaid/"
      cp ${quartz.passthru.vendorDir}/* "${stateDir}/public.new/static/vendor/"
      chmod -R u+w "${stateDir}/public.new/static"

      # ---- 4. swap in atomically -------------------------------------------
      rm -rf "${stateDir}/public.old"
      if [ -d "${stateDir}/public" ]; then
        mv "${stateDir}/public" "${stateDir}/public.old"
      fi
      mv "${stateDir}/public.new" "${stateDir}/public"
      rm -rf "${stateDir}/public.old" "$work"
    '';
  };
in
{
  options.cg.service.digital-garden = {
    enable = lib.mkEnableOption "Digital garden (published subset of the Obsidian vault)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8086;
      description = "Port the static site is served on (localhost only)";
    };

    vaultRepo = lib.mkOption {
      type = lib.types.str;
      default = "git@github.com:corygyarmathy/personal-notes.git";
      description = "Git remote for the notes vault. Cloned in full; only published notes are served.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Branch to build from";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "garden.gyarmathy.co";
      description = "Public base URL, without scheme (Quartz wants it bare)";
    };

    siteTitle = lib.mkOption {
      type = lib.types.str;
      default = "Cory Gyarmathy";
      description = "Site title shown in the header";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar expression for rebuilds";
    };

    footerLinks = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        GitHub = "https://github.com/corygyarmathy";
      };
      description = ''
        Links shown in the site footer. Empty by default: upstream's default
        config puts the Quartz project's own GitHub and Discord here, which
        would otherwise be published as though they were yours.
      '';
    };

    disabledPlugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "created-modified-date" # needs @napi-rs/simple-git
        "latex" # needs @myriaddreamin/rehype-typst
        "favicon" # needs sharp
        "og-image" # needs sharp
      ];
      description = ''
        Quartz plugins to force off. The defaults are the ones whose own npm
        dependencies are native and not vendored by the quartz package; leaving
        any of them enabled aborts the build, because Quartz responds to a
        plugin that fails to instantiate by putting undefined in the component
        list rather than skipping it.

        Note that created-modified-date is what reads dates from git, so
        published pages fall back to frontmatter and filesystem mtime.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."digital-garden/deploy-key" = {
      sopsFile = ../../../secrets/homelab.yaml;
      owner = "digital-garden";
      group = "digital-garden";
      mode = "0400";
    };

    users.users.digital-garden = {
      isSystemUser = true;
      group = "digital-garden";
      home = stateDir;
      description = "Digital garden site builder";
    };
    users.groups.digital-garden = { };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 digital-garden digital-garden -"
    ];

    systemd.services.digital-garden-build = {
      description = "Build the digital garden from published vault notes";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "digital-garden";
        Group = "digital-garden";
        StateDirectory = "digital-garden";
        WorkingDirectory = stateDir;

        # The deploy key is copied in rather than read from /run/secrets
        # because ssh refuses key files it cannot stat under ProtectSystem.
        ExecStartPre = pkgs.writeShellScript "digital-garden-key" ''
          install -m 0400 ${config.sops.secrets."digital-garden/deploy-key".path} ${stateDir}/deploy-key
        '';
        ExecStart = lib.getExe buildScript;

        # Hardening: this pulls a private repo and runs a Node build, so it gets
        # network and nothing else.
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # V8 JIT needs W^X off
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        ReadWritePaths = [ stateDir ];
      };
    };

    systemd.timers.digital-garden-build = {
      description = "Rebuild the digital garden";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };

    # Plain HTTP on a local port. TLS, the public hostname and rate limiting are
    # supplied by cg.service.reverse-proxy / cloudflare-tunnel, same as every
    # other service — this just has no upstream process to proxy to.
    services.caddy.virtualHosts.":${toString cfg.port}" = {
      extraConfig = ''
        root * ${stateDir}/public
        encode gzip zstd
        file_server
        header {
          X-Content-Type-Options "nosniff"
          Referrer-Policy "strict-origin-when-cross-origin"
        }
      '';
    };

    # Caddy must be able to traverse into the generated site.
    users.users.caddy.extraGroups = [ "digital-garden" ];
  };
}
