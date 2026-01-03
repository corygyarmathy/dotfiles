## Proposed Implementation Plan

Assuming you want me to create a fresh, clean implementation, here's my plan:

### File Structure

```
dotfiles/
├── modules/
│   ├── nixos/
│   │   └── auto-upgrade.nix          # Unified NixOS module (server + desktop base)
│   └── home/
│       └── desktop/
│           └── auto-upgrade-desktop.nix  # Home-manager module (waybar, notifications)
├── packages/
│   └── nixos-upgrade-scripts/        # Python scripts as a proper Nix package
│       ├── default.nix
│       └── src/
│           ├── __init__.py
│           ├── check_updates.py      # Check for nix + firmware updates
│           ├── apply_updates.py      # Apply updates (switch or boot)
│           ├── state.py              # State management helpers
│           ├── waybar_status.py      # Waybar JSON output
│           ├── waybar_click.py       # Waybar click handler
│           └── common.py             # Shared utilities
└── configs/
    └── waybar/
        └── nixos-upgrade.css         # Portable CSS for the module
```

### Module Design

**`auto-upgrade.nix` (NixOS module):**

- Options:
    - `mode`: `"server"` | `"desktop"` (affects auto-reboot behavior)
    - `flake`: Path to flake directory
    - `schedule`: Systemd calendar spec for checks
    - `firmware.enable`: Enable fwupd integration
    - `rebootWindow`: Time window for server auto-reboots
    - `backgroundBuild.enable`: Enable low-priority pre-staging
    - `backgroundBuild.nice`: Nice level (default 19)
    - `backgroundBuild.ionice`: IO class (default "idle")
- Provides:
    - `nixos-upgrade-check.service` - Checks for updates, writes state
    - `nixos-upgrade-build.service` - Background build (if enabled)
    - `nixos-upgrade-apply.service` - Applies updates (switch or boot+reboot)
    - `nixos-upgrade-check.timer` - Scheduled checks
    - Catchup logic for missed windows

**`auto-upgrade-desktop.nix` (Home-manager module):**

- Options:
    - `enable`: Enable desktop integration
    - `waybar.enable`: Add waybar module
- Provides:
    - Waybar status script (reads state, outputs JSON)
    - Waybar click handler (left-click: apply/show status, right-click: cancel)
    - Notification on completion/failure
    - Watches state directory for changes

### Python Script Design

All scripts will:

- Use type hints compatible with pyright
- Use only stdlib + minimal well-maintained dependencies
- Shell out to `nvd`, `fwupdmgr`, `nixos-rebuild`, `git`, `notify-send`
- Read/write state to `/var/lib/nixos-auto-upgrade/state.json`

**State file schema:**

json

```json
{
  "status": "idle|checking|building|applying|error",
  "last_check": "2025-01-01T04:00:00Z",
  "last_apply": "2025-01-01T04:05:00Z",
  "pending_updates": {
    "nix": {
      "count": 5,
      "summary": "5 updated, 2 added",
      "requires_reboot": true,
      "diff": "..."
    },
    "firmware": { "count": 1, "devices": ["UEFI Device Firmware"] }
  },
  "error_message": null,
  "build_complete": false
}
```

### Waybar States

| State                             | Icon     | Tooltip                  | Class               | Left-click        | Right-click |
| --------------------------------- | -------- | ------------------------ | ------------------- | ----------------- | ----------- |
| No updates                        | (hidden) | -                        | -                   | -                 | -           |
| Updates available (no reboot)     | 📦       | "5 pkgs, 1 firmware"     | `updates-available` | Apply switch      | -           |
| Updates available (reboot needed) | 🔄       | "Kernel update + 3 pkgs" | `updates-reboot`    | Apply boot+reboot | -           |
| Building                          | ⏳       | "Building... (23%)"      | `building`          | Show status       | Cancel      |
| Error                             | ⚠️       | "Build failed: ..."      | `error`             | View logs         | Dismiss     |

### Workflow

1. **Timer fires** (or catchup on boot/resume)
2. **Check service** runs:
   - `nix flake update --dry-run` to see if inputs changed
   - `nixos-rebuild build --dry-run` to see package changes
   - `fwupdmgr get-updates` for firmware
   - Writes state with pending updates
3. **If updates found and `backgroundBuild.enable`:**
   - Triggers build service at low priority
   - Builds to `/nix/store`, doesn't activate
   - Updates state when complete
4. **User sees waybar icon**, clicks
5. **Apply service** runs:
   - If build already done: fast switch/boot
   - If not: full build then switch/boot
   - For firmware: runs `fwupdmgr update`
   - If reboot needed: triggers reboot (desktop: after confirmation)
6. **Notification** on success/failure
