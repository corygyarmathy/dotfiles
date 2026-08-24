# Digital Garden - publish selected notes from the Obsidian vault as a website
#
# Provides:
# - Periodic build of a public site from the private personal-notes vault
# - Only notes explicitly marked `publish: true` are ever included
# - Static output served by Caddy, exposed like any other service
#
# Architecture:
# - Timer -> oneshot builder. The builder obtains the vault, filters it down to
#   published notes, then runs the site generator over the filtered tree.
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
# Two gates stand in front of the build: a stat-only walk of the vault, and a
# content hash of the filtered tree. Editing a private note clears the first and
# stops at the second; touching nothing stops at the first. Both fold in a hash
# of the build inputs, so a Hugo upgrade or an option change still forces a
# rebuild of an otherwise untouched vault.
#
# ════════════════════════════════════════════════════════════════════════════
# The publish boundary
# ════════════════════════════════════════════════════════════════════════════
# publish-filter.py copies ONLY notes containing a literal `publish: true` into
# a staging tree, and the generator is pointed at that staging tree — never at
# the vault. An unmarked note is therefore not merely unrendered, it is not
# present on disk for the generator to see, so no template mistake or upstream
# default change can expose it.
#
# The builder then RE-CHECKS the marker on every staged note before rendering,
# and refuses to build if one is missing. That second layer has already earned
# its keep once: when the filter was deliberately broken to see what would
# happen, it is what caught the leak. It lives in the builder rather than in
# the generator so that it does not depend on which program renders the tree —
# and rather than in publish-filter.py, because a check inside the thing being
# checked is worth less.
#
# Known residual leak: a published note that writes [[Some Private Note]] in
# prose still renders the words "Some Private Note" (as plain text, not a
# link). Titles you type into published notes are published.
#
# The filter also FLATTENS published notes to the root, so a URL is /some-essay/
# and stays that way when the vault is reorganised, and derives `published:`
# dates from a ledger at ${stateDir}/dates.json rather than asking for them to
# be written by hand. Both are explained in publish-filter.py.
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

  obsidian-headless = self.packages.${pkgs.stdenv.hostPlatform.system}.obsidian-headless;

  # Rendering and serving live under ./lib so that the local preview runs the
  # same code as this service does. See the headers there.
  serve = import ./lib/serve.nix { inherit lib; };
  hugo = import ./lib/hugo.nix { inherit pkgs lib; };

  renderer = hugo.mkRenderer {
    inherit (cfg)
      baseUrl
      siteTitle
      styleSheet
      footerLinks
      ;
  };

  stateDir = "/var/lib/digital-garden";
  vaultDir = "${stateDir}/vault";

  # Identifies everything that can change the generated site other than the
  # notes themselves. Folded into the build stamp so that a Hugo upgrade or a
  # changed option rebuilds even when the vault is untouched — otherwise the
  # skip-if-unchanged check below would happily serve a stale site forever.
  buildInputsId = builtins.hashString "sha256" (
    builtins.toJSON {
      # The renderer's store path already moves when Hugo, the templates, the
      # stylesheet or any rendering option does — that is the whole content of
      # the derivation. Only the filter has to be named separately, because it
      # runs before the renderer is reached.
      renderer = toString renderer;
      filter = toString ./publish-filter.py;
    }
  );

  buildScript = pkgs.writeShellApplication {
    name = "digital-garden-build";
    runtimeInputs = [
      pkgs.git
      pkgs.openssh
      # pyyaml for publish-filter.py, which rewrites the frontmatter of every
      # published note (dates, aliases, description).
      (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
      renderer
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
      # Two gates, cheapest first. The render itself is not the expensive step
      # — Hugo and Pagefind finish the whole site in a few hundred milliseconds
      # — but the filter walks the entire vault, and most vault changes touch
      # unpublished notes.
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
      # The ledger lives outside the staging tree because it must survive it:
      # staging is rebuilt from scratch every run, and the first date a note was
      # seen is not recoverable from anywhere else.
      python3 ${./publish-filter.py} "${vaultDir}" "${stateDir}/content" \
        "${stateDir}/dates.json"

      # Defence in depth, and the reason it is here rather than in the
      # generator: this guards the staging tree itself, so it holds no matter
      # what renders it. The one time publish-filter.py was deliberately
      # broken, a second layer like this is what stopped the leak.
      #
      # Cheap enough to be unconditional: the staging tree is the published
      # set, not the vault. If anything in it lost its marker on the way
      # through the filter, refuse to build rather than serve it.
      unmarked=$(grep -rLE '^publish:[[:space:]]*true[[:space:]]*(#.*)?$' \
        --include='*.md' "${stateDir}/content" || true)
      if [ -n "$unmarked" ]; then
        echo "staged notes are missing 'publish: true'; refusing to build:" >&2
        echo "$unmarked" >&2
        exit 1
      fi

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
      # Everything about how the site is generated lives in lib/hugo.nix, which
      # the local preview calls the same way. Passing no stylesheet takes the
      # one baked into the renderer, which is cfg.styleSheet.
      ${lib.getExe renderer} "${stateDir}/content" "${stateDir}/public.new"

      # ---- 5. swap in atomically -------------------------------------------
      rm -rf "${stateDir}/public.old"
      if [ -d "${stateDir}/public" ]; then
        mv "${stateDir}/public" "${stateDir}/public.old"
      fi
      mv "${stateDir}/public.new" "${stateDir}/public"
      rm -rf "${stateDir}/public.old"

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
      description = "Public base URL, without scheme; the scheme is added by the renderer";
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
        stops after the filter. Hugo runs only when the published set actually
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
        Links shown in the site footer, as a name -> URL map. Empty by
        default, which renders no list at all rather than an empty one.
      '';
    };

    renderer = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      default = renderer;
      defaultText = lib.literalMD "the renderer built from the options above";
      description = ''
        The `digital-garden-render` program this host's settings produce,
        exposed so that `nix run .#garden-preview` can run the very same one.
        Reading it from here rather than rebuilding it in the flake is what
        stops the preview and the server drifting apart.
      '';
    };

    styleSheet = lib.mkOption {
      type = lib.types.path;
      default = ./lib/hugo/assets/main.css;
      defaultText = lib.literalMD "the stylesheet the templates are written against";
      description = ''
        The site's entire stylesheet, built as `assets/main.css`. Not an
        override layered onto a theme — there is no theme underneath, so this
        file and the templates in `lib/hugo/layouts` are the whole design and
        are written against each other.

        Replacing it means restyling the site rather than adjusting it; to
        change a colour or a margin, edit the default in place.

        A path rather than a block of inline lines, so that the preview can be
        pointed at the file in the working tree and re-render on save. Inline
        Nix lines can only reach the preview through a fresh evaluation of the
        whole host, which is most of what made tuning this site tedious.
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

        # Hardening: this clones a private repo, so it gets network and
        # nothing else.
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
        # Nothing here JITs: the filter is CPython, and Hugo and Pagefind are
        # a Go and a Rust binary. This was off when the site was rendered by a
        # Node toolchain that needed writable-executable pages; that toolchain
        # is gone and the exemption went with it.
        MemoryDenyWriteExecute = true;
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
    services.caddy.virtualHosts.":${toString cfg.port}".extraConfig =
      serve.caddyConfig "${stateDir}/public";

    # Caddy must be able to traverse into the generated site.
    users.users.caddy.extraGroups = [ "digital-garden" ];
  };
}
