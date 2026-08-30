# NixOS Remote Installation Guide

This guide covers automated NixOS installation using **nixos-anywhere** with **disko** for declarative disk partitioning and **sops-nix** for secrets management.

## Overview

The traditional NixOS installation process is manual and repetitive. This setup automates it:

| Component          | Purpose                                                                 |
| ------------------ | ----------------------------------------------------------------------- |
| **disko**          | Declarative disk partitioning - define your partition layout in Nix     |
| **nixos-anywhere** | Remote installation over SSH - no USB required after initial boot       |
| **sops-nix**       | Secrets management - encrypted secrets that only your hosts can decrypt |

### The SOPS Bootstrapping Problem

There's a chicken-and-egg problem with sops:

1. You need the host's age key to encrypt secrets for it
2. The age key is derived from the SSH host key
3. The SSH host key is generated during installation

**Solution**: Pre-generate the SSH host key before installation, derive the age key, update your secrets, then install with the pre-generated key.

## Prerequisites

### On Your Development Machine (xps15)

1. **Enter the dev shell** (provides sops, age, ssh-to-age):

   ```bash
   cd ~/dotfiles
   nix develop
   ```

2. **Ensure your flake includes disko**:

   ```nix
   # flake.nix inputs
   disko.url = "github:nix-community/disko";
   disko.inputs.nixpkgs.follows = "nixpkgs";
   ```

3. **Add disko to your mkHost modules**:

   ```nix
   modules = [
     # ... other modules
     disko.nixosModules.disko
   ];
   ```

### On the Target Machine

1. **Boot from NixOS installer USB**
2. **Close the graphical installer** (if it opens)
3. **Set a password for SSH access**:

   ```bash
   sudo passwd nixos
   ```

4. **Get the IP address**:

   ```bash
   ip a
   ```

## File Structure

After setup, your host directory should look like:

```
hosts/
└── homelab02/
    ├── default.nix      # Main configuration
    ├── disko.nix        # Disk partitioning
    └── hardware.nix     # Hardware config (auto-generated)
```

## Disko Configuration

Create `hosts/<hostname>/disko.nix`:

```nix
# Simple UEFI + ext4 setup
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/disk/by-id/PLACEHOLDER";  # Overridden by --disk flag
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              priority = 1;
              name = "ESP";
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "defaults" "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                mountOptions = [ "defaults" "noatime" ];
              };
            };
          };
        };
      };
    };
  };
}
```

Import it in your `default.nix`:

```nix
{
  imports = [
    ./disko.nix
    ./hardware.nix
    # ... other imports
  ];
}
```

## Installation Methods

### Method 1: Automated Script (Recommended)

Use the provided `nixos-install-remote.sh` script:

```bash
# From your dotfiles directory
./nixos-install-remote.sh homelab02 192.168.1.100 --disk /dev/nvme0n1
```

The script handles:

- SSH connectivity checks
- Pre-generating SSH host keys
- Deriving age public key
- Updating .sops.yaml
- Re-encrypting secrets
- Running nixos-anywhere with all correct options

### Method 2: Manual Steps

If you prefer to understand each step:

#### Step 1: Prepare SSH Access

From your dev machine:

```bash
# Add your SSH key to the installer
ssh-copy-id nixos@192.168.1.100
```

#### Step 2: Generate SSH Host Key

```bash
# Create temp directory
mkdir -p .install-temp

# Generate key pair
ssh-keygen -t ed25519 -f .install-temp/homelab02_ssh_host_ed25519_key -N "" -C "root@homelab02"
```

#### Step 3: Derive Age Key

```bash
# Convert SSH public key to age public key
ssh-to-age < .install-temp/homelab02_ssh_host_ed25519_key.pub
# Output: age1abc123...
```

#### Step 4: Update .sops.yaml

Add the age key to your `.sops.yaml`, and put it in the rules for the files
this host reads — **its own and `shared.yaml`, and no others.** A host that is a
recipient of a file it never reads can decrypt secrets it has no use for, which
is what `secrets/README.md` exists to prevent and what `checks/secrets.nix`
fails on.

```yaml
keys:
  # ... existing keys
  - &homelab02 age1abc123...  # The key from step 3

creation_rules:
  - path_regex: secrets/shared\.yaml$
    key_groups:
      - age:
          - *coryg
          - *homelab01
          - *homelab02  # Add new host

  - path_regex: secrets/homelab02\.yaml$
    key_groups:
      - age:
          - *coryg
          - *homelab02  # Add new host
```

#### Step 5: Re-encrypt Secrets

```bash
# Re-key the files this host reads - its own, and the shared one
sops updatekeys secrets/<hostname>.yaml secrets/shared.yaml
```

#### Step 6: Prepare Extra Files

```bash
# Create directory structure for host keys
mkdir -p .install-temp/extra-files/etc/ssh
cp .install-temp/homelab02_ssh_host_ed25519_key .install-temp/extra-files/etc/ssh/ssh_host_ed25519_key
cp .install-temp/homelab02_ssh_host_ed25519_key.pub .install-temp/extra-files/etc/ssh/ssh_host_ed25519_key.pub
chmod 600 .install-temp/extra-files/etc/ssh/ssh_host_ed25519_key
chmod 644 .install-temp/extra-files/etc/ssh/ssh_host_ed25519_key.pub
```

#### Step 7: Run nixos-anywhere

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#homelab02 \
  --disk main /dev/nvme0n1 \
  --extra-files .install-temp/extra-files \
  --generate-hardware-config nixos-generate-config ./hosts/homelab02/hardware.nix \
  nixos@192.168.1.100
```

#### Step 8: Commit Changes

```bash
git add .sops.yaml secrets/ hosts/homelab02/hardware.nix
git commit -m "Add homelab02 configuration"
git push
```

## Post-Installation

### Verify the Installation

After the system reboots:

```bash
# SSH to the new system
ssh coryg@192.168.1.100

# Verify sops secrets are working
sudo cat /run/secrets/users/coryg  # Should show password hash
```

### Set Up Auto-Upgrades

If your config uses auto-upgrades from a local repo:

```bash
# Clone dotfiles to the expected location
sudo git clone https://github.com/YOUR_USER/dotfiles.git /etc/nixos
sudo chown -R root:wheel /etc/nixos
```

### Hardware Configuration

The `hardware.nix` file was auto-generated. Review it:

```bash
# Check the generated file
cat hosts/homelab02/hardware.nix
```

If it contains `fileSystems` entries, remove them - disko handles disk configuration.

## Advanced: Disko Configurations

### With Swap Partition

```nix
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/PLACEHOLDER";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          swap = {
            size = "8G";
            content = {
              type = "swap";
              randomEncryption = true;
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
```

### With BTRFS and Subvolumes

```nix
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/PLACEHOLDER";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];  # Force overwrite
              subvolumes = {
                "/root" = {
                  mountpoint = "/";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
                "/home" = {
                  mountpoint = "/home";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
                "/nix" = {
                  mountpoint = "/nix";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
                "/persist" = {
                  mountpoint = "/persist";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
              };
            };
          };
        };
      };
    };
  };
}
```

### NAS Configuration (Multiple Disks)

For homelab02 with separate OS and data disks:

```nix
{
  disko.devices = {
    disk = {
      # OS disk (SSD)
      os = {
        type = "disk";
        device = "/dev/disk/by-id/PLACEHOLDER";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      # Data disk (HDD) - handled separately or via mergerfs
      # Consider managing data disks outside disko if they contain existing data
    };
  };
}
```

## Troubleshooting

### SSH Connection Refused

```bash
# On the installer machine, ensure SSH is running
sudo systemctl start sshd

# Set password if not done
sudo passwd nixos
```

### Disk Not Found

```bash
# List available disks on target
ssh nixos@192.168.1.100 "lsblk -d -o NAME,SIZE,TYPE,MODEL"

# Use /dev/disk/by-id for reliability
ssh nixos@192.168.1.100 "ls -la /dev/disk/by-id/"
```

### SOPS Decryption Fails After Install

1. Verify the SSH host key matches:

   ```bash
   # On the installed system
   sudo cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age
   ```

2. Compare with the key in `.sops.yaml`

3. If different, the extra-files didn't apply correctly. Re-install or manually replace the key.

### Hardware Config Conflicts with Disko

If `hardware.nix` contains `fileSystems` entries, they'll conflict with disko. Remove them:

```nix
# hardware.nix should NOT contain:
# fileSystems."/" = { ... };
# fileSystems."/boot" = { ... };

# Disko handles all filesystem configuration
```

## Quick Reference

```bash
# Enter dev shell
nix develop

# Install new host
./nixos-install-remote.sh <hostname> <ip> --disk /dev/nvme0n1

# Re-encrypt secrets after adding a key
sops updatekeys secrets/<hostname>.yaml secrets/shared.yaml

# Test disko config without installing
nix run github:nix-community/disko -- --mode dry-run ./hosts/homelab02/disko.nix

# Rebuild existing system
sudo nixos-rebuild switch --flake .#hostname
```
