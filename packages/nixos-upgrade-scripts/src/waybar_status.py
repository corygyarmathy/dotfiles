#!/usr/bin/env python3
"""
Waybar status script for NixOS upgrade module.

Outputs JSON suitable for waybar's custom module format:
{
    "text": "icon",
    "tooltip": "description",
    "class": "css-class"
}

The module is hidden when no updates are pending and system is up-to-date.
"""

from __future__ import annotations

import json
import sys

from common import UpgradeState, UpgradeStatus, format_timestamp_for_display, load_state


def escape_json_string(s: str) -> str:
    """Escape a string for JSON output."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main() -> int:
    """Main entry point."""
    state: UpgradeState = load_state()

    text: str = ""
    tooltip: str = ""
    css_class: str = ""

    # Determine display based on state
    if state.status == UpgradeStatus.CHECKING:
        text = ""
        tooltip = "Checking for updates..."
        css_class = "checking"

    elif state.status == UpgradeStatus.BUILDING:
        text = "󰔟"
        tooltip = "Building updates in background..."
        css_class = "building"

    elif state.status == UpgradeStatus.APPLYING:
        text = "⟳"
        tooltip = "Applying updates..."
        css_class = "applying"

    elif state.status == UpgradeStatus.ERROR:
        text = "⚠"
        error_msg = state.error_message or "Unknown error"
        # Truncate long error messages
        if len(error_msg) > 100:
            error_msg = error_msg[:97] + "..."
        tooltip = f"Error: {error_msg}"
        css_class = "error"

    elif state.has_pending_updates():
        summary: str = state.get_summary()

        if state.requires_reboot():
            text = "🔄"
            tooltip = f"Updates pending (reboot required): {summary}"
            css_class = "reboot-needed"
        else:
            if state.build_complete:
                text = "📦"
                tooltip = f"Updates ready to apply: {summary}"
                css_class = "ready"
            else:
                text = "↓"
                tooltip = f"Updates available: {summary}"
                css_class = "updates-available"

    else:
        # No updates, system up to date - show checkmark with last check time
        text = "✓"
        if state.last_check:
            # Parse and format the last check time
            try:
                formatted_last_check: str = format_timestamp_for_display(
                    iso_timestamp=state.last_check
                )
                # Format as relative or absolute time
                tooltip = f"Up to date (checked {formatted_last_check})"
            except (ValueError, AttributeError):
                tooltip = "Up to date"
        else:
            tooltip = "Up to date (never checked)"
        css_class = "up-to-date"

    # Output JSON
    output: dict[str, str] = {
        "text": text,
        "tooltip": escape_json_string(tooltip),
        "class": css_class,
    }
    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
