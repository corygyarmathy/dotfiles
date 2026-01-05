#!/usr/bin/env python3
"""
DDC Brightness Waybar Status

Outputs JSON for waybar custom module showing current brightness status.
"""

from __future__ import annotations

import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal


@dataclass
class WaybarOutput:
    """Output format for waybar custom module."""

    text: str
    tooltip: str
    css_class: Literal["auto", "override", "inactive"]

    def to_json(self) -> str:
        return json.dumps(
            {
                "text": self.text,
                "tooltip": self.tooltip,
                "class": self.css_class,
            }
        )


def get_state_dir() -> Path:
    """Get the state directory for runtime data."""
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return Path(runtime_dir) / "ddc-brightness"


def get_override_file() -> Path:
    """Get the path to the manual override file."""
    return get_state_dir() / "manual_override"


def get_state_file() -> Path:
    """Get the path to the current state file."""
    return get_state_dir() / "current_state.json"


def get_override_remaining() -> int | None:
    """Get remaining override time in minutes, or None if not active."""
    override_file = get_override_file()
    if not override_file.exists():
        return None

    try:
        expire_time = float(override_file.read_text().strip())
        remaining = expire_time - time.time()
        if remaining > 0:
            return int(remaining / 60)
        return None
    except Exception:
        return None


def get_waybar_status() -> WaybarOutput:
    """Get current status formatted for waybar."""
    state_file = get_state_file()

    # Check if state file exists
    if not state_file.exists():
        return WaybarOutput(
            text="?",
            tooltip="DDC brightness daemon not running",
            css_class="inactive",
        )

    try:
        state = json.loads(state_file.read_text())
        brightness = state.get("base_brightness", "?")

        # Check override status
        override_remaining = get_override_remaining()
        if override_remaining is not None:
            return WaybarOutput(
                text=f"{brightness}%",
                tooltip=f"Manual override: {override_remaining} min remaining",
                css_class="override",
            )

        # Build tooltip with monitor details
        monitors = state.get("monitors", {})
        tooltip_lines = [f"Auto brightness: {brightness}%"]

        if monitors:
            for display, level in monitors.items():
                tooltip_lines.append(f"Display {display}: {level}%")

        return WaybarOutput(
            text=f"{brightness}%",
            tooltip="\n".join(tooltip_lines),
            css_class="auto",
        )

    except Exception as e:
        return WaybarOutput(
            text="!",
            tooltip=f"Error reading state: {e}",
            css_class="inactive",
        )


def main() -> None:
    """Main entry point."""
    output = get_waybar_status()
    print(output.to_json())


if __name__ == "__main__":
    main()
