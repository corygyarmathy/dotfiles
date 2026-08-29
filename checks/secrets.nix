# A secret this fleet declares is a secret its files actually carry, and every
# host that reads a file can open it.
#
# The failure this replaces: `sops.secrets."media-stack/sonar/api"` evaluates,
# builds, deploys, and then fails at activation - on the machine, at 04:00,
# with the unit that needed it dead until someone reads the journal. sops-nix's
# own `validateSopsFiles` only checks that a file is sops-encrypted; nothing
# checks that the *name* is in it. Nothing had to, while every host could
# decrypt every file and a typo was the only way to get this wrong. Splitting
# the files per host (secrets/README.md) adds a second way - a name in the
# right file for the wrong host - so the check has to exist before the split is
# safe.
#
# Both questions are answerable without decrypting anything: sops leaves the
# key structure and the recipient list in clear text, which is the whole reason
# this can run in CI at all.
#
# Three properties:
#
#   1. Every `sops.secrets.<name>` any host declares - system or home-manager -
#      exists in the file that host would read it from.
#   2. Every host that reads a file is a recipient of it, and so is the user
#      key. This is the one that makes the re-key (step 3 in secrets/README.md)
#      safe: removing a key a host still needs fails here rather than on the
#      next activation.
#   3. A file whose recipients have been narrowed stays narrowed - see
#      `narrowedFiles` below.
#
# It also runs property 1 against a name that is deliberately wrong, so a
# passing run means the comparison happened rather than that it found nothing
# to compare.
{
  pkgs,
  self,
}:
let
  inherit (pkgs) lib;

  hosts = [
    "homelab01"
    "homelab02"
    "xps15"
  ];

  configOf = name: self.nixosConfigurations.${name}.config;

  # `"${...}"` rather than `toString`: the interpolation keeps the string
  # context, which is what makes each secrets file an input of this derivation
  # and therefore present in the sandbox.
  declOf = host: layer: name: secret: {
    inherit host layer name;
    file = "${secret.sopsFile}";
  };

  systemDecls = host: lib.mapAttrsToList (declOf host "system") (configOf host).sops.secrets;

  # The user's own key material is decrypted by home-manager with the user's
  # age key, not the host key, so it is declared on a different side of the
  # configuration and would otherwise go unchecked.
  homeDecls =
    host:
    lib.concatLists (
      lib.mapAttrsToList (
        user: hm: lib.mapAttrsToList (declOf host "home:${user}") (hm.sops.secrets or { })
      ) (configOf host).home-manager.users
    );

  declarations = lib.concatMap (host: systemDecls host ++ homeDecls host) hosts;

  # Step 3 of the re-key has not run for any file yet: every file is still
  # encrypted to every host, exactly as secrets.yaml and homelab.yaml were, so
  # the split itself cannot cost a host access to anything. Naming a file here
  # turns its surplus recipients from a note into a failure, which is what the
  # step-3 PR does after `sops updatekeys` - one line per file.
  narrowedFiles = [ ];

  # Property 1 has to be able to fail. A name nothing declares, checked the
  # same way, so a run that reports nothing has actually compared something.
  selfTest = {
    name = "backups/restic/passwrod";
    file = "${self}/secrets/shared.yaml";
  };

  spec = {
    inherit declarations narrowedFiles selfTest;
    # The anchor naming the user key in secrets/.sops.yaml. Every file has to
    # be readable by it or the secret can never be edited again except from one
    # of the hosts itself.
    userKeyAnchor = "coryg";
  };
in
pkgs.runCommand "check-secrets"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.yq-go
    ];
    passAsFile = [ "spec" ];
    spec = builtins.toJSON spec;
    sopsConfig = "${../secrets/.sops.yaml}";
  }
  ''
    set -euo pipefail

    fail=0
    report() {
      echo "  $*" >&2
      fail=1
    }

    # A file reached through a relative path lands in the store on its own,
    # under a hashed name; the file's own name is what a reader recognises.
    shortName() { basename "$1" | sed 's/^[a-z0-9]\{32\}-//'; }

    # Host name -> age public key, from the anchors in secrets/.sops.yaml.
    # sops itself resolves those anchors away, so the parsed document cannot
    # say which key belongs to which host; the anchor names are the only place
    # that mapping is written down.
    sed -n 's/^ *- &\([A-Za-z0-9_-]\+\) \(age1[a-z0-9]\+\) *$/\1 \2/p' "$sopsConfig" > anchors.txt
    if [ ! -s anchors.txt ]; then
      echo "check-secrets: no age key anchors found in $sopsConfig" >&2
      exit 1
    fi

    keyOf() { awk -v n="$1" '$1 == n { print $2 }' anchors.txt; }

    # One YAML parse per file, keyed by a digest of its path so the name is
    # safe to use on disk.
    plain() {
      local f="$1" h
      h=$(printf '%s' "$f" | sha256sum | cut -c1-16)
      if [ ! -f "yaml-$h.json" ]; then
        yq -o=json '.' "$f" > "yaml-$h.json"
      fi
      printf '%s' "yaml-$h.json"
    }

    # ---------------------------------------------------------------------
    # 1. Every declared name is in the file the host reads it from.
    # ---------------------------------------------------------------------
    declared=0
    while IFS=$'\t' read -r host layer name file; do
      declared=$((declared + 1))
      if ! jq -e --arg p "$name" 'getpath($p | split("/")) != null' "$(plain "$file")" > /dev/null; then
        report "$host ($layer) declares $name, which is not in $(shortName "$file")"
      fi
    done < <(jq -r '.declarations[] | [.host, .layer, .name, .file] | @tsv' "$specPath")

    # The same comparison against a name that is not there. If this does not
    # come back missing, the loop above proves nothing.
    selfTestName=$(jq -r '.selfTest.name' "$specPath")
    selfTestFile=$(jq -r '.selfTest.file' "$specPath")
    if jq -e --arg p "$selfTestName" 'getpath($p | split("/")) != null' \
        "$(plain "$selfTestFile")" > /dev/null; then
      echo "check-secrets: the self-test name $selfTestName exists - this check cannot fail" >&2
      exit 1
    fi

    # ---------------------------------------------------------------------
    # 2 and 3. Recipients: everyone who needs the file, and nobody else once
    #          the file has been narrowed.
    # ---------------------------------------------------------------------
    userKey=$(keyOf "$(jq -r '.userKeyAnchor' "$specPath")")
    [ -n "$userKey" ] || { echo "check-secrets: no anchor for the user key" >&2; exit 1; }

    jq -r '.declarations[].file' "$specPath" | sort -u > files.txt

    while read -r file; do
      base=$(shortName "$file")
      jq -r '.sops.age[].recipient' "$(plain "$file")" | sort -u > "recipients.txt"

      # Required: the user key, plus the key of every host that reads this
      # file from its system configuration. A home-manager secret is decrypted
      # with the user key, so it adds no host requirement.
      : > required.txt
      echo "$userKey" >> required.txt
      while read -r host; do
        k=$(keyOf "$host")
        if [ -z "$k" ]; then
          report "$host reads $base but has no age key anchor in secrets/.sops.yaml"
        else
          echo "$k" >> required.txt
        fi
      done < <(jq -r --arg f "$file" \
        '.declarations[] | select(.file == $f and .layer == "system") | .host' "$specPath" | sort -u)
      sort -u required.txt -o required.txt

      missing=$(comm -23 required.txt recipients.txt)
      if [ -n "$missing" ]; then
        while read -r k; do
          who=$(awk -v k="$k" '$2 == k { print $1 }' anchors.txt)
          report "$base is not encrypted to ''${who:-$k}, which reads it"
        done <<< "$missing"
      fi

      surplus=$(comm -13 required.txt recipients.txt)
      if [ -n "$surplus" ]; then
        names=$(while read -r k; do
          awk -v k="$k" '$2 == k { print $1 }' anchors.txt
        done <<< "$surplus" | paste -sd' ')
        if jq -e --arg f "$base" '.narrowedFiles | index($f)' "$specPath" > /dev/null; then
          report "$base is narrowed but is still encrypted to: $names"
        else
          echo "note: $base is still encrypted to $names, which do not read it (step 3 of the re-key)"
        fi
      fi
    done < files.txt

    if [ "$fail" -ne 0 ]; then
      echo "" >&2
      echo "secrets/ and the configuration disagree - see secrets/README.md." >&2
      exit 1
    fi

    # Reported so a passing run says what it covered. A count that quietly
    # falls to zero is how this check would stop meaning anything.
    echo "ok: $declared declarations across $(wc -l < files.txt) files, all present and decryptable"
    touch $out
  ''
