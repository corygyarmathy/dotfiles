# Secrets

Encrypted with [sops](https://github.com/getsops/sops) and age, decrypted by [sops-nix](https://github.com/Mic92/sops-nix) at activation. Every file here is safe to commit; none of them can be read without a key that is not in this repository.

## The layout

**A secret lives in the file for the host that needs it.** "Needs" means a `sops.secrets."<name>"` declaration in that host's evaluated configuration — not that the service happens to run there.

| File             | Read by                | Holds                                                                                                                    |
| ---------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `shared.yaml`    | both servers           | Only what two machines must agree on. Every entry is justified in `cg.sops-nix.sharedSecrets` (`modules/nixos/sops-nix.nix`). |
| `homelab01.yaml` | homelab01              | Everything only homelab01 declares — the tunnel, Grafana, miniflux, wallabag, the garden.                                  |
| `homelab02.yaml` | homelab02              | Everything only homelab02 declares — qBittorrent, the VPN, grimmory's database.                                            |
| `xps15.yaml`     | xps15                  | The laptop's wifi PSKs. Nothing else on a machine that leaves the house.                                                   |
| `operator.yaml`  | nobody — the user only | Secrets that belong to a person rather than a machine: the user's SSH keys, CI tokens, and web logins for services that keep their own user database. |

Two consequences worth stating, because both are easy to get wrong:

- **`prowlarr/api` is in `homelab02.yaml`, and Prowlarr runs on homelab01.** The file follows the declaration, and the only thing that declares that key is cross-seed, on homelab02. The service's location is not the question.
- **A secret for a service that is switched off still lives in its host's file.** `vikunja/jwt-secret` and `digital-garden/deploy-key` are both parked in `homelab01.yaml` so that flipping the toggle works without an editing session. `operator.yaml` is for what no host will ever declare, not for what no host declares today.

Nothing in `modules/` names a file. A module writes `sops.secrets."<name>" = { ... }` and `cg.sops-nix` decides where the name is read from: `secrets/<hostname>.yaml`, or `shared.yaml` if the name is in `cg.sops-nix.sharedSecrets`. That option is the whole of the mapping and the place to change it.

## The check

`nix flake check` runs `checks/secrets.nix`, which asserts that every declared name exists in the file its host would read, and that every host reading a file is a recipient of it. sops leaves the key structure and the recipient list in clear text, so both are answerable in CI without decrypting anything.

A misspelt name fails the gate:

```
homelab01 (system) declares media-stack/sonar/api, which is not in homelab01.yaml
```

That used to be an activation failure at 04:00 on the machine.

## Common operations

```bash
sops secrets/homelab01.yaml    # edit (encrypts on save; keeps the file's existing recipients)
sops -d secrets/shared.yaml    # print decrypted, for debugging
```

Adding a secret: put it in the file for the host that will declare it, add the `sops.secrets` entry to the module that consumes it, and rebuild. If it needs to be readable by both servers, add it to `shared.yaml` **and** to `cg.sops-nix.sharedSecrets` with a line saying why two machines must agree on one value.

Moving a secret between files: `sops -d --extract` it out of one and into the other, then delete it from the first. The check will tell you if you got it backwards.

## Keys

`.sops.yaml` lists every key and which files it opens. Host keys are derived from `/etc/ssh/ssh_host_ed25519_key`, so a host has no key file to back up — and no key material lives in this repo.

```bash
cat ~/.config/sops/age/keys.txt | grep "public key:"   # the user key
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub          # a host key
```

**After adding or removing a key, `sops updatekeys <file>`.** Editing a file with `sops` does not re-key it; the recipient list only changes when you say so.

### After a reinstall

Reinstalling a host regenerates its SSH host key and therefore its age key, and the files it reads can no longer be opened by it.

1. Copy the user age key back to `~/.config/sops/age/keys.txt`.
2. `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub` on the new host.
3. Replace that host's anchor in `.sops.yaml`.
4. `sops updatekeys secrets/<host>.yaml secrets/shared.yaml` — only the files that host reads, which is what the per-host split buys you.
5. Commit and rebuild.

## Narrowing the recipients

The per-host split landed in two parts on purpose, and **part two has not run yet**.

Today every file is still encrypted to all four keys, exactly as `secrets.yaml` and `homelab.yaml` were. What has changed is which file each host *reads*: homelab01 opens `homelab01.yaml` and `shared.yaml` and nothing else. So a mis-scoped secret shows up as a missing name — which the check catches before a deploy — rather than as a host that cannot decrypt.

`check-secrets` prints what is still outstanding on every run:

```
note: xps15.yaml is still encrypted to homelab02 homelab01, which do not read it (step 3 of the re-key)
```

To finish, once the split has been deployed to both servers and everything that consumes a secret has been seen running:

1. Delete the `# step 3: remove` lines from `creation_rules` in `.sops.yaml`.
2. `sops updatekeys secrets/shared.yaml secrets/homelab01.yaml secrets/homelab02.yaml secrets/xps15.yaml secrets/operator.yaml`
3. Add the five file names to `narrowedFiles` in `checks/secrets.nix`, so a key that reappears is a failure rather than a note.
4. Confirm the diff is only `sops:` metadata and ciphertext, and that the plaintext did not move — compare digests, do not print the values:

   ```bash
   sops -d --output-type json secrets/shared.yaml | sha256sum   # before and after
   ```

5. Deploy homelab01 by hand and verify before letting the nightly take homelab02.

Doing this in the same change as the split is what would make the split unrecoverable, which is why it is a separate one.
