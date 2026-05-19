# Waybar modifier key indicator
#
# Displays colored symbols on the Waybar when modifier keys are held.
# Designed for home-row mod feedback on the ZSA Voyager, but works with
# any keyboard that sends standard modifier keycodes via evdev.
#
# Prerequisites:
#   - User must be in the 'input' group to read /dev/input/* devices
#   - Waybar config.jsonc must include the custom module (see below)
#
# Waybar config.jsonc — add to your "modules-right" (or wherever you prefer):
#
#   "modules-right": ["custom/modifiers", ...],
#
#   "custom/modifiers": {
#     "exec": "waybar-mod-indicator",
#     "return-type": "json",
#     "tooltip": true
#   }
#
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.waybar.modifiers;

  pythonWithEvdev = pkgs.python3.withPackages (ps: [ ps.evdev ]);

  modIndicatorPy = pkgs.writeText "waybar-mod-indicator.py" ''
    #!/usr/bin/env python3
    """Monitor keyboard modifier state and output Waybar JSON with pango markup.

    Watches evdev for modifier key events from a ZSA keyboard (Voyager, Moonlander,
    ErgoDox EZ, etc.) and prints a JSON line to stdout each time modifier state
    changes. Waybar picks up each line as a module update.

    Falls back to any keyboard with standard modifier keycodes if no ZSA device
    is found. Reconnects automatically on device disconnection.
    """

    import json
    import sys
    import time

    import evdev
    from evdev import ecodes

    # --- Configuration -----------------------------------------------------------

    # Rose Pine palette — matches waybar/rose-pine.css
    COLORS = {
        "shift": "#eb6f92",  # Love
        "ctrl":  "#31748f",  # Pine
        "alt":   "#f6c177",  # Gold
        "super": "#c4a7e7",  # Iris
    }

    SYMBOLS = {
        "shift": "S",
        "ctrl":  "C",
        "alt":   "A",
        "super": "M",
    }

    # Display order (left to right in the indicator)
    MOD_ORDER = ["super", "alt", "ctrl", "shift"]

    # Map evdev keycodes → canonical modifier name
    MOD_KEYS = {
        ecodes.KEY_LEFTSHIFT:  "shift",
        ecodes.KEY_RIGHTSHIFT: "shift",
        ecodes.KEY_LEFTCTRL:   "ctrl",
        ecodes.KEY_RIGHTCTRL:  "ctrl",
        ecodes.KEY_LEFTALT:    "alt",
        ecodes.KEY_RIGHTALT:   "alt",
        ecodes.KEY_LEFTMETA:   "super",
        ecodes.KEY_RIGHTMETA:  "super",
    }

    # Keywords to identify ZSA keyboards in evdev device names
    ZSA_KEYWORDS = ["zsa", "voyager", "moonlander", "ergodox"]

    RETRY_INTERVAL = 2  # seconds between device scans when disconnected


    # --- Functions ---------------------------------------------------------------

    # Suffixes used by secondary ZSA evdev interfaces that advertise key
    # capabilities but don't actually carry keystroke events.
    ZSA_SECONDARY_SUFFIXES = ["keyboard", "consumer control", "system control"]

    def find_keyboard():
        """Find the best keyboard evdev device to monitor.

        ZSA keyboards expose multiple evdev nodes. The one that actually
        carries keystroke events is the *base* device whose name is just
        the product name (e.g. "ZSA Technology Labs Voyager") without a
        suffix like "Keyboard", "Consumer Control", or "System Control".
        The suffixed "Keyboard" node advertises the same capabilities but
        produces no events — so we must prefer the base name.

        Falls back to any device with modifier key capabilities if no ZSA
        device is found.
        """
        zsa_primary = []
        zsa_secondary = []
        other_candidates = []

        for path in evdev.list_devices():
            try:
                device = evdev.InputDevice(path)
            except (OSError, PermissionError):
                continue

            caps = device.capabilities()
            if ecodes.EV_KEY not in caps:
                continue

            keys = caps[ecodes.EV_KEY]
            if ecodes.KEY_LEFTSHIFT not in keys:
                continue

            name_lower = device.name.lower()
            if any(kw in name_lower for kw in ZSA_KEYWORDS):
                # Check if this is a secondary interface (has a suffix
                # beyond the base product name)
                is_secondary = any(
                    name_lower.endswith(suffix)
                    for suffix in ZSA_SECONDARY_SUFFIXES
                )
                if is_secondary:
                    zsa_secondary.append(device)
                else:
                    zsa_primary.append(device)
            else:
                other_candidates.append(device)

        candidates = zsa_primary or zsa_secondary or other_candidates
        return candidates[0] if candidates else None


    def emit(active_mods):
        """Print a JSON line for Waybar to consume."""
        if not active_mods:
            line = {"text": "", "class": "inactive", "tooltip": "No modifiers"}
        else:
            parts = []
            names = []
            for mod in MOD_ORDER:
                if mod in active_mods:
                    color = COLORS[mod]
                    symbol = SYMBOLS[mod]
                    parts.append(f"<span color='{color}' font_weight='bold'>{symbol}</span>")
                    names.append(mod.capitalize())
            line = {
                "text": "  ".join(parts),
                "class": "active",
                "tooltip": " + ".join(names),
            }

        print(json.dumps(line), flush=True)


    def monitor(device):
        """Read evdev events and emit state changes."""
        active = set()
        emit(active)

        for event in device.read_loop():
            if event.type != ecodes.EV_KEY or event.code not in MOD_KEYS:
                continue

            mod = MOD_KEYS[event.code]
            prev = frozenset(active)

            if event.value > 0:   # 1 = press, 2 = held repeat
                active.add(mod)
            else:                 # 0 = release
                active.discard(mod)

            if frozenset(active) != prev:
                emit(active)


    def main():
        """Entry point — scan, monitor, and reconnect on failure."""
        # Emit initial blank state so Waybar renders the module immediately
        emit(set())

        while True:
            keyboard = find_keyboard()
            if keyboard is not None:
                try:
                    monitor(keyboard)
                except OSError:
                    # Device disconnected mid-read — will retry
                    emit(set())
            time.sleep(RETRY_INTERVAL)


    if __name__ == "__main__":
        main()
  '';

  waybar-mod-indicator = pkgs.writeShellScriptBin "waybar-mod-indicator" ''
    exec ${pythonWithEvdev}/bin/python3 ${modIndicatorPy}
  '';

in
{
  options.cg.home.waybar.modifiers.enable =
    lib.mkEnableOption "Waybar modifier key indicator for home-row mods";

  config = lib.mkIf cfg.enable {
    home.packages = [ waybar-mod-indicator ];

    xdg.configFile."waybar/modifiers.css".text = ''
      /* Modifier key indicator — home-row mod feedback */

      #custom-modifiers {
        font-family: monospace;
        font-size: 13px;
        padding: 0 6px;
        min-width: 0;
        /* No transition — feedback must be instant */
        transition: none;
      }

      #custom-modifiers.inactive {
        /* Collapse when no modifiers held */
        padding: 0;
        margin: 0;
        min-width: 0;
      }

      #custom-modifiers.active {
        padding: 0 8px;
      }
    '';
  };
}
