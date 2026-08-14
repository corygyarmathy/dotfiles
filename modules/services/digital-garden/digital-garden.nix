# Digital Garden - publish selected notes from the Obsidian vault as a website
#
# Provides:
# - Periodic build of a public site from the private personal-notes vault
# - Only notes explicitly marked `publish: true` are ever included
# - Static output served by Caddy, exposed like any other service
#
# Architecture:
# - Timer -> oneshot builder. The builder obtains the vault, filters it down to
#   published notes, then runs Quartz over the filtered tree.
# - Serving is plain HTTP on 127.0.0.1:<port>, which lets this slot into
#   cg.service.reverse-proxy.services (TLS + LAN) and
#   cg.service.cloudflare-tunnel.services (public) with no special casing.
#
# Where the vault comes from is `source`:
# - "git" clones the notes repo, so publishing waits on whatever commits it.
# - "obsidian-sync" runs the headless client here (digital-garden-sync.service),
#   so notes land within seconds of being written on any device and nothing has
#   to commit anything. Requires a one-time `digital-garden-vault-setup` run.
# Either way the whole vault lands on disk and is filtered afterwards, so the
# publish boundary below is unchanged.
#
# The timer fires often (default: minutely) because a run is normally a no-op.
# Two gates stand in front of the expensive Quartz pass: a stat-only walk of the
# vault, and a content hash of the filtered tree. Editing a private note clears
# the first and stops at the second; touching nothing stops at the first. Both
# fold in a hash of the build inputs, so a Quartz upgrade or an option change
# still forces a rebuild of an otherwise untouched vault.
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
# Secrets required in secrets/homelab.yaml, depending on `source`:
#   git:           digital-garden/deploy-key
#                  <ssh private key with read access to the vault repo>
#   obsidian-sync: digital-garden/obsidian-token
#                  <contents of ~/.config/obsidian-headless/auth_token after
#                   running `ob login` — `ob` prefers $OBSIDIAN_AUTH_TOKEN, so
#                   the credential never lands in the state directory>
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
  obsidian-headless = self.packages.${pkgs.stdenv.hostPlatform.system}.obsidian-headless;

  stateDir = "/var/lib/digital-garden";
  vaultDir = "${stateDir}/vault";

  # Identifies everything that can change the generated site other than the
  # notes themselves. Folded into the build stamp so that a Quartz upgrade or a
  # changed option rebuilds even when the vault is untouched — otherwise the
  # skip-if-unchanged check below would happily serve a stale site forever.
  buildInputsId = builtins.hashString "sha256" (
    builtins.toJSON {
      quartz = qpkg;
      mkConfig = toString mkConfig;
      pluginMap = toString pluginMap;
      filter = toString ./publish-filter.py;
      mermaid = toString quartz.passthru.mermaidDist;
      vendor = toString quartz.passthru.vendorDir;
      inherit (cfg)
        baseUrl
        siteTitle
        footerLinks
        disabledPlugins
        ;
    }
  );

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
      # The skip gates lean on find/sha256sum/sort/grep. NixOS puts these on a
      # service's PATH by default, but this unit is hardened enough that relying
      # on the ambient environment for its correctness is asking for trouble.
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
    ];
    text = ''
      set -euo pipefail

      # ---- 1. get the vault -------------------------------------------------
      ${
        if cfg.source == "git" then
          ''
            export GIT_SSH_COMMAND="ssh -i ${stateDir}/deploy-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
            if [ -d "${vaultDir}/.git" ]; then
              git -C "${vaultDir}" fetch --depth 1 origin "${cfg.branch}"
              git -C "${vaultDir}" reset --hard "origin/${cfg.branch}"
              git -C "${vaultDir}" clean -fdx
            else
              rm -rf "${vaultDir}"
              git clone --depth 1 --branch "${cfg.branch}" "${cfg.vaultRepo}" "${vaultDir}"
            fi
          ''
        else
          ''
            # digital-garden-sync.service owns this directory; nothing to fetch.
            if [ ! -d "${vaultDir}" ]; then
              echo "vault not present at ${vaultDir}." >&2
              echo "Run digital-garden-vault-setup once, then start digital-garden-sync." >&2
              exit 1
            fi
          ''
      }

      # ---- 2. skip early if nothing could possibly have changed --------------
      # Two gates, cheapest first, because the Quartz pass below is by far the
      # most expensive step and most vault changes touch unpublished notes.
      #
      # Gate one is a stat-only walk: no file is opened, so this stays cheap
      # enough to run every minute. Dotfiles are excluded to match the filter,
      # which ignores .obsidian/.git/.sync.lock — otherwise sync churn in
      # .obsidian would rebuild the site constantly.
      vault_stamp="${stateDir}/stamp-vault"
      content_stamp="${stateDir}/stamp-content"
      vault_id=$(
        {
          echo "${buildInputsId}"
          find "${vaultDir}" -name '.*' -prune -o -type f -printf '%P %s %T@\n' | sort
        } | sha256sum | cut -d' ' -f1
      )
      if [ "$(cat "$vault_stamp" 2>/dev/null || true)" = "$vault_id" ]; then
        echo "vault unchanged; nothing to do"
        exit 0
      fi

      # ---- 3. reduce it to only what is marked publish: true -----------------
      python3 ${./publish-filter.py} "${vaultDir}" "${stateDir}/content"

      # Gate two: the vault moved, but did the PUBLISHED set? Editing a private
      # note changes vault_id and nothing else, and that is the common case.
      content_id=$(
        {
          echo "${buildInputsId}"
          find "${stateDir}/content" -type f -exec sha256sum {} + | sort -k2
        } | sha256sum | cut -d' ' -f1
      )
      if [ "$(cat "$content_stamp" 2>/dev/null || true)" = "$content_id" ]; then
        echo "published content unchanged; skipping rebuild"
        # Record the cheaper identity so the next run stops at gate one.
        echo "$vault_id" > "$vault_stamp"
        exit 0
      fi

      # ---- 4. build ---------------------------------------------------------
      # Quartz is designed to run in-tree: it reads ./package.json from CWD, and
      # quartz/components/Head.tsx imports "../../.quartz/plugins" relative to
      # its own source file. Symlinking the package in resolves that path back
      # into the read-only store, so the tree has to be a writable COPY and the
      # CLI has to be invoked from that copy — not via ${quartz}/bin/quartz,
      # which would resolve its transpile cache into the store and fail.
      work="${stateDir}/work"
      rm -rf "$work"
      mkdir -p "$work"
      # Everything EXCEPT node_modules, which is symlinked back in below. cp -r
      # follows the store symlinks inside it and expands ~19MB of tree into
      # ~2.3GB, only for the next line to delete it again.
      ( cd ${qpkg} && find . -mindepth 1 -maxdepth 1 ! -name node_modules \
          -exec cp -r --no-preserve=mode,ownership {} "$work"/ \; )
      ln -s ${qpkg}/node_modules "$work/node_modules"
      cd "$work"

      ${mkConfig} quartz.config.default.yaml ${pluginMap} quartz.config.yaml \
        "${cfg.baseUrl}" "${cfg.siteTitle}" \
        "${lib.concatStringsSep "," cfg.disabledPlugins}" \
        ${lib.escapeShellArg (builtins.toJSON cfg.footerLinks)} \
        "$work/enabled-plugins.json"

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

      # ---- 5. swap in atomically -------------------------------------------
      rm -rf "${stateDir}/public.old"
      if [ -d "${stateDir}/public" ]; then
        mv "${stateDir}/public" "${stateDir}/public.old"
      fi
      mv "${stateDir}/public.new" "${stateDir}/public"
      rm -rf "${stateDir}/public.old" "$work"

      # Only after the new site is actually serving, so a failed build is retried
      # on the next tick rather than being recorded as done.
      echo "$content_id" > "$content_stamp"
      echo "$vault_id" > "$vault_stamp"
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

    source = lib.mkOption {
      type = lib.types.enum [
        "git"
        "obsidian-sync"
      ];
      default = "git";
      description = ''
        Where the vault comes from.

        "git" clones vaultRepo, so publishing waits for whatever commits it —
        which in practice means a desktop machine being awake with the
        obsidian-git plugin running.

        "obsidian-sync" runs the headless client on this host instead, so notes
        arrive within seconds of being written on any device and nothing has to
        commit anything. Git then plays no part in publishing and is free to be
        just history and backup.

        Both put the whole vault on disk here and filter afterwards, so the
        publish boundary is identical either way.

        "obsidian-sync" needs one-time interactive setup; see
        digital-garden-vault-setup.
      '';
    };

    vaultRepo = lib.mkOption {
      type = lib.types.str;
      default = "git@github.com:corygyarmathy/personal-notes.git";
      description = ''
        Git remote for the notes vault, used when source = "git". Cloned in
        full; only published notes are served.
      '';
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = ''Branch to build from, used when source = "git"'';
    };

    remoteVault = lib.mkOption {
      type = lib.types.str;
      default = "_gyarmathy";
      description = ''
        Name of the remote Obsidian Sync vault, used when source =
        "obsidian-sync". Run `ob sync-list-remote` to see the available names.
      '';
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
      default = "minutely";
      description = ''
        systemd OnCalendar expression for rebuild checks.

        This is a check, not a rebuild: a run whose vault is untouched does a
        stat-only walk and exits, and one that changed only unpublished notes
        stops after the filter. Quartz runs only when the published set actually
        moved, so a short interval costs very little and caps publish latency at
        roughly one interval.

        A systemd.path unit would be the obvious event-driven alternative, but
        path units do not watch subdirectories recursively, which is useless for
        a vault with folders in it.
      '';
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
    sops.secrets = lib.mkMerge [
      (lib.mkIf (cfg.source == "git") {
        "digital-garden/deploy-key" = {
          sopsFile = ../../../secrets/homelab.yaml;
          owner = "digital-garden";
          group = "digital-garden";
          mode = "0400";
        };
      })
      (lib.mkIf (cfg.source == "obsidian-sync") {
        "digital-garden/obsidian-token" = {
          sopsFile = ../../../secrets/homelab.yaml;
          owner = "digital-garden";
          group = "digital-garden";
          mode = "0400";
        };
      })
    ];

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
        ExecStartPre = lib.mkIf (cfg.source == "git") (
          pkgs.writeShellScript "digital-garden-key" ''
            install -m 0400 ${config.sops.secrets."digital-garden/deploy-key".path} ${stateDir}/deploy-key
          ''
        );
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
        # No RandomizedDelaySec: this is a cheap check that usually exits within
        # a second, and jitter here is just latency between writing a note and
        # seeing it published. There is nothing to spread the load of.
      };
    };

    # ── Obsidian Sync as the vault source ────────────────────────────────────
    # Continuous headless sync, so a note written on any device is on this host
    # within seconds and no machine has to be awake to commit anything.
    systemd.services.digital-garden-sync = lib.mkIf (cfg.source == "obsidian-sync") {
      description = "Obsidian headless sync for the digital garden vault";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment.XDG_CONFIG_HOME = "${stateDir}/obsidian";

      serviceConfig = {
        User = "digital-garden";
        Group = "digital-garden";
        StateDirectory = "digital-garden";
        WorkingDirectory = stateDir;

        # `ob` reads OBSIDIAN_AUTH_TOKEN in preference to its own token file, so
        # the credential never has to be written into the state directory.
        EnvironmentFile = config.sops.templates."digital-garden-obsidian-env".path;

        ExecStart = "${lib.getExe obsidian-headless} sync --continuous --path ${vaultDir}";
        Restart = "always";
        RestartSec = 30;

        # Same hardening as the builder. This one holds a credential with access
        # to the entire vault, so it gets network and nothing else either.
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

    sops.templates."digital-garden-obsidian-env" = lib.mkIf (cfg.source == "obsidian-sync") {
      content = ''
        OBSIDIAN_AUTH_TOKEN=${config.sops.placeholder."digital-garden/obsidian-token"}
      '';
      owner = "digital-garden";
      group = "digital-garden";
      mode = "0400";
    };

    # One-time interactive setup. `ob sync-setup` needs the end-to-end
    # encryption password, which is deliberately not stored anywhere, so this
    # cannot be done declaratively — it has to be run once by hand as root.
    environment.systemPackages = lib.mkIf (cfg.source == "obsidian-sync") [
      obsidian-headless
      (pkgs.writeShellApplication {
        name = "digital-garden-vault-setup";
        runtimeInputs = [ obsidian-headless ];
        text = ''
          # Runs `ob` as the digital-garden user against the same state the
          # sync service uses, so the vault registration lands where the
          # service will look for it.
          if [ "$(id -u)" -ne 0 ]; then
            echo "run this as root" >&2
            exit 1
          fi

          run_ob() {
            runuser -u digital-garden -- env \
              XDG_CONFIG_HOME=${stateDir}/obsidian \
              OBSIDIAN_AUTH_TOKEN="$(cat ${config.sops.secrets."digital-garden/obsidian-token".path})" \
              ${lib.getExe obsidian-headless} "$@"
          }

          install -d -o digital-garden -g digital-garden -m 0700 ${stateDir}/obsidian

          echo "==> remote vaults visible to this token:"
          run_ob sync-list-remote

          echo
          echo "==> connecting ${cfg.remoteVault} -> ${vaultDir}"
          echo "    (you will be prompted for the end-to-end encryption password)"
          run_ob sync-setup --vault ${lib.escapeShellArg cfg.remoteVault} --path ${vaultDir}

          # Download-only. This host has no business writing to the vault, and
          # mirror-remote means a stray local edit here can never propagate out
          # to the notes on your other devices.
          run_ob sync-config --path ${vaultDir} --mode mirror-remote \
            --device-name "$(hostname)-digital-garden"

          echo
          echo "==> done. Start the sync service with:"
          echo "    systemctl start digital-garden-sync"
        '';
      })
    ];

    # Plain HTTP on a local port. TLS, the public hostname and rate limiting are
    # supplied by cg.service.reverse-proxy / cloudflare-tunnel, same as every
    # other service — this just has no upstream process to proxy to.
    services.caddy.virtualHosts.":${toString cfg.port}" = {
      extraConfig = ''
        root * ${stateDir}/public
        encode gzip zstd
        # Quartz emits `<slug>.html` but links to `<slug>`, so a bare
        # file_server 404s on every internal link. Try the literal path first
        # (assets, and the folder pages that emit as directories), then the
        # directory index, then the extension the page was actually written as.
        try_files {path} {path}/ {path}.html
        file_server
        # Quartz also generates a styled 404 page; without this Caddy answers
        # with its own empty one.
        handle_errors {
          rewrite * /404.html
          file_server
        }
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
