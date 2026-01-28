# Cory's NixOS Configuration

A modular NixOS configuration using flakes and home-manager.

## Structure

```
dotfiles/
├── flake.nix              # Main entry point
├── hosts/                 # Per-machine configurations
│   └── xps15/
│       ├── default.nix    # Host configuration
│       ├── hardware.nix   # Hardware-specific settings
│       ├── home.nix       # User's home-manager config
│       └── thermald-conf.xml
├── modules/               # Reusable modules
│   ├── nixos/             # System-level modules
│   └── home/              # Home-manager modules
│       ├── shell/         # Shell tools (starship, zellij)
│       ├── desktop/       # Desktop environment (hyprland, waybar)
│       ├── development/   # Dev tools (nvim, git)
│       ├── terminals/     # Terminal emulators
│       └── media/         # Media applications
├── configs/               # Portable configuration files
│   ├── nvim/              # Neovim configuration
│   ├── zellij/            # Zellij configuration
│   ├── starship/          # Starship prompt
│   └── ...
├── overlays/              # Package overlays
├── packages/              # Custom package definitions
├── secrets/               # SOPS-encrypted secrets
└── wallpapers/            # Wallpaper images
```

## Usage

### Build and switch

```bash
sudo nixos-rebuild switch --flake .#xps15
```

### Update flake inputs

```bash
nix flake update
```

### Add a new host

1. Create `hosts/hostname/` directory
2. Copy and modify `default.nix`, `hardware.nix`, `home.nix` from an existing host
3. Add to `flake.nix`:

   ```nix
   nixosConfigurations.hostname = mkHost {
     hostname = "hostname";
     system = "x86_64-linux";
   };
   ```

## Module System

### Enabling modules

In `hosts/hostname/default.nix` (NixOS modules):

```nix
cg = {
  hyprland.enable = true;
  nvidia.enable = true;
  # ...
};
```

In `hosts/hostname/home.nix` (Home-manager modules):

```nix
cg.home = {
  nvim.enable = true;
  zellij.enable = true;
  # ...
};
```

### Creating a new module

1. Create the module file in the appropriate directory
2. Add to the relevant `default.nix` imports
3. Follow the pattern:

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.cg.home.modulename;
in {
  options.cg.home.modulename.enable = lib.mkEnableOption "Module description";

  config = lib.mkIf cfg.enable {
    # Configuration here
  };
}
```

## Portable Configurations

Configuration files in `configs/` are designed to work on non-NixOS systems.
They are symlinked by home-manager using `xdg.configFile`.

To use on a non-NixOS system, simply copy or symlink the relevant directories
to your `~/.config/`.

## Secrets Management (TODO)

This configuration uses [sops-nix](https://github.com/Mic92/sops-nix) for secrets management.

Setup:

1. Generate an age key: `age-keygen -o ~/.config/sops/age/keys.txt`
2. Add the public key to `secrets/.sops.yaml`
3. Encrypt secrets: `sops secrets/secrets.yaml`
4. Enable sops in your host configuration

## Homelab Infrastructure

```
┌─────────────────────────────────────────────────────────────────┐
│                        homelab02 (NAS)                          │
│  HP Elitedesk 800 G6 • i7 10th Gen • 2×4TB HDDs                 │
├─────────────────────────────────────────────────────────────────┤
│  Primary Role: Storage + Download                               │
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ qBittorrent │  │ cross-seed  │  │  unpackerr  │              │
│  │  + gluetun  │  │             │  │             │              │
│  └─────────────┘  └─────────────┘  └─────────────┘              │
│                                                                 │
│  Storage: /srv/media (primary) ──── NFS export ────────────▶    │
│           - downloads/                                          │
│           - movies/                                             │
│           - tv/                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                         NFS mount
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       homelab01 (Compute)                       │
│  Dell Optiplex 5080 • i5 • Quick Sync                           │
├─────────────────────────────────────────────────────────────────┤
│  Primary Role: Media Management + Streaming                     │
│                                                                 │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐            │
│  │ Jellyfin │ │  Sonarr  │ │  Radarr  │ │ Prowlarr │            │
│  │(transcode│ │          │ │          │ │          │            │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘            │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐            │
│  │  Bazarr  │ │Jellyseerr│ │ Recyclarr│ │  Wizarr  │            │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘            │
│                                                                 │
│  Storage: /srv/media (NFS mount from homelab02)                 │
└─────────────────────────────────────────────────────────────────┘
```
