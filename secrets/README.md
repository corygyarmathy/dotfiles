# Secrets Management with SOPS-Nix

## Overview

SOPS-Nix allows you to store encrypted secrets in your git repository.
Secrets are encrypted with age keys and decrypted at build/activation time.

SOPS (Secrets OPerationS) encrypts sensitive data so you can safely store it in git. Without sops, you'd have to either:

- Keep secrets out of your dotfiles repo (annoying, not reproducible)
- Risk accidentally committing plaintext secrets (dangerous)

With sops, your `secrets/secrets.yaml` file is encrypted at rest - it's safe to commit because only someone with the right age key can decrypt it.

### How It Works

```
┌─────────────────┐     sops encrypt      ┌──────────────────────┐
│ Plaintext YAML  │ ──────────────────►   │ Encrypted YAML       │
│ (you edit this) │                       │ (stored in git)      │
└─────────────────┘                       └──────────────────────┘
                                                    │
                                                    │ nixos-rebuild
                                                    ▼
                                          ┌──────────────────────┐
                                          │ Decrypted at runtime │
                                          │ /run/secrets/...     │
                                          │ ~/.ssh/id_github     │
                                          └──────────────────────┘
```

## Your Current Setup

You already have age keys configured in `secrets/.sops.yaml`:

- **User key (coryg):** `age1g02vwy6867g9v4w58d4v52h3q37slhd0gjyygh9eramdfshw0ats0wkc5x`
- **Host key (xps15):** `age1aqvdthnw8k7wn3z90qf8f8d3fupchhf55ecdafn5yr4axad75f3qvst4dg`

## Setup Steps

### Step 1: Verify Your Age Keys

**Check if your user age key exists:**

```bash
cat ~/.config/sops/age/keys.txt
```

If it doesn't exist, create one:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

Then update `secrets/.sops.yaml` with the public key shown.

**Get your host's age key (derived from SSH host key):**

```bash
sudo cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age
```

Verify this matches what's in `.sops.yaml` for `&xps15`.

### Step 2: Create Your Secrets File

Create the actual secrets file:

```bash
cd ~/git/dotfiles
sops secrets/secrets.yaml
```

This will open your editor. Add secrets in YAML format:

```yaml
# SSH Keys
private_keys:
  github: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAA...
    -----END OPENSSH PRIVATE KEY-----

# API Tokens
tokens:
  openai: sk-xxxxxxxxxxxxxxxxxxxxxxxx
  github: ghp_xxxxxxxxxxxxxxxxxxxxxxxx

# Other secrets
passwords:
  some_service: supersecretpassword
```

Save and close - sops will encrypt it automatically.

### Step 3: Enable sops-nix in Your Configuration

**In `hosts/xps15/default.nix`:**

```nix
cg = {
  # ... other options ...
  sops-nix.enable = true;  # Change from false to true
};
```

**In `hosts/xps15/home.nix`:**

```nix
cg.home = {
  # ... other options ...
  sops-nix.enable = true;  # Change from false to true
};
```

### Step 4: Define Which Secrets to Decrypt

**For system-level secrets** (in `modules/nixos/sops-nix.nix`):

```nix
sops.secrets = {
  "private_keys/github" = {
    mode = "0600";
    owner = config.users.users.coryg.name;
    group = config.users.users.coryg.group;
    path = "/home/coryg/.ssh/id_github_system";
  };
};
```

**For user-level secrets** (in `modules/home/security/sops-nix.nix`):

```nix
sops.secrets = {
  "private_keys/github" = {
    mode = "0600";
    path = "${config.home.homeDirectory}/.ssh/id_github";
  };
  "tokens/openai" = {
    mode = "0600";
    path = "${config.home.homeDirectory}/.config/openai/api_key";
  };
};
```

### Step 5: Rebuild

```bash
sudo nixos-rebuild switch --flake .#xps15
```

## File Structure

```
secrets/
├── .sops.yaml          # Defines which keys can decrypt which files
├── secrets.yaml        # Your encrypted secrets (safe to commit!)
└── secrets.yaml.example # Template showing structure (optional)
```

## Common Operations

### Edit Secrets

```bash
sops secrets/secrets.yaml
```

### Add a New Secret

1. Edit with `sops secrets/secrets.yaml`
2. Add the secret in YAML format
3. Save and close
4. Add the secret definition in your nix module
5. Rebuild

### Rotate Keys

If you need to add a new machine or remove access:

1. Update `secrets/.sops.yaml` with new keys
2. Run: `sops updatekeys secrets/secrets.yaml`
3. Commit the changes

### View Decrypted Secrets (for debugging)

```bash
sops -d secrets/secrets.yaml
```

## Example: Migrating Your GitHub SSH Key

### 1. Add the key to secrets.yaml

```bash
sops secrets/secrets.yaml
```

Add:

```yaml
private_keys:
  github: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    <paste your key here>
    -----END OPENSSH PRIVATE KEY-----
```

### 2. Update home sops-nix module

```nix
sops.secrets = {
  "private_keys/github" = {
    mode = "0600";
    path = "${config.home.homeDirectory}/.ssh/id_github";
  };
};
```

### 3. Update SSH config to use the managed key

Your existing `modules/home/development/ssh.nix` already references `~/.ssh/id_github`,
so it should work automatically after rebuild.

### 4. Rebuild and test

```bash
sudo nixos-rebuild switch --flake .#xps15
ssh -T git@github.com
```

## Troubleshooting

### "Failed to decrypt"

- Ensure your age key is in `~/.config/sops/age/keys.txt`
- Check the public key matches what's in `.sops.yaml`
- Run `sops updatekeys secrets/secrets.yaml` if keys changed

### "Permission denied" on secret file

- Check the `mode` and `owner` settings in your secret definition
- Ensure the target directory exists

### Secret not appearing at expected path

- Check `path` is set correctly in the secret definition
- Look at `/run/secrets/` for NixOS-level secrets
- Check `systemctl --user status sops-nix` for home-manager secrets

## Security Notes

1. **Never commit unencrypted secrets** - Always use `sops` to edit
2. **Backup your age keys** - Store `~/.config/sops/age/keys.txt` securely
3. **Use separate keys per machine** - Allows revoking access per-device
4. **The `secrets.yaml` file is safe to commit** - It's encrypted!
