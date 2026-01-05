#!/usr/bin/env python3
"""
DDC Brightness Control CLI

Manual control utility for DDC/CI monitor brightness.
Provides commands for getting/setting brightness, managing auto-adjust override,
and detecting monitors.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn


@dataclass
class DetectedMonitor:
    """A monitor detected via ddcutil."""

    display_num: str
    model: str = ""
    serial: str = ""


def get_state_dir() -> Path:
    """Get the state directory for runtime data."""
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    state_dir = Path(runtime_dir) / "ddc-brightness"
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir


def get_override_file() -> Path:
    """Get the path to the manual override file."""
    return get_state_dir() / "manual_override"


def get_state_file() -> Path:
    """Get the path to the current state file."""
    return get_state_dir() / "current_state.json"


def detect_monitors() -> list[DetectedMonitor]:
    """Detect connected external monitors via ddcutil."""
    try:
        result = subprocess.run(
            ["ddcutil", "detect", "--brief"],
            capture_output=True,
            text=True,
            timeout=30,
        )

        monitors: list[DetectedMonitor] = []
        current: dict[str, str] = {}

        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("Display"):
                if current:
                    monitors.append(
                        DetectedMonitor(
                            display_num=current.get("display_num", ""),
                            model=current.get("model", ""),
                            serial=current.get("serial", ""),
                        )
                    )
                parts = line.split()
                current = {"display_num": parts[1] if len(parts) > 1 else ""}
            elif line.startswith("Model:"):
                current["model"] = line.split(":", 1)[1].strip()
            elif line.startswith("Serial number:"):
                current["serial"] = line.split(":", 1)[1].strip()

        if current:
            monitors.append(
                DetectedMonitor(
                    display_num=current.get("display_num", ""),
                    model=current.get("model", ""),
                    serial=current.get("serial", ""),
                )
            )

        return monitors

    except subprocess.TimeoutExpired:
        print("Error: ddcutil detect timed out", file=sys.stderr)
        return []
    except Exception as e:
        print(f"Error detecting monitors: {e}", file=sys.stderr)
        return []


def get_brightness(display_num: str) -> int | None:
    """Get current brightness for a specific display."""
    try:
        result = subprocess.run(
            ["ddcutil", "getvcp", "10", "--display", display_num, "--brief"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            # Parse output like "VCP 10 C 50 100"
            parts = result.stdout.strip().split()
            if len(parts) >= 4:
                return int(parts[3])
    except Exception:
        pass
    return None


def set_brightness(display_num: str, brightness: int) -> bool:
    """Set brightness for a specific display."""
    brightness = max(0, min(100, brightness))

    try:
        result = subprocess.run(
            ["ddcutil", "setvcp", "10", str(brightness), "--display", display_num],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.returncode == 0
    except Exception:
        return False


def set_override(duration_minutes: int = 60) -> None:
    """Set manual override to pause auto-adjustment."""
    override_file = get_override_file()
    # Store the time when override should expire
    expire_time = time.time() + (duration_minutes * 60)
    _ = override_file.write_text(str(expire_time))


def clear_override() -> None:
    """Clear manual override to resume auto-adjustment."""
    override_file = get_override_file()
    if override_file.exists():
        override_file.unlink()


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
        else:
            # Expired, clean up
            override_file.unlink()
            return None
    except Exception:
        return None


def cmd_set(args: argparse.Namespace) -> int:
    """Handle the 'set' command."""
    # Setting brightness triggers override
    set_override(60)

    if args.display is not None:
        # Set specific display
        if set_brightness(str(args.display), args.brightness):
            print(f"Display {args.display}: set to {args.brightness}%")
            return 0
        else:
            print(
                f"Failed to set brightness for display {args.display}", file=sys.stderr
            )
            return 1
    else:
        # Set all displays
        monitors = detect_monitors()
        if not monitors:
            print("No monitors detected", file=sys.stderr)
            return 1

        success = True
        for monitor in monitors:
            if set_brightness(monitor.display_num, args.brightness):
                print(f"Display {monitor.display_num}: set to {args.brightness}%")
            else:
                print(
                    f"Failed to set brightness for display {monitor.display_num}",
                    file=sys.stderr,
                )
                success = False

        return 0 if success else 1


def cmd_get(args: argparse.Namespace) -> int:
    """Handle the 'get' command."""
    monitors = detect_monitors()
    if not monitors:
        print("No monitors detected", file=sys.stderr)
        return 1

    for monitor in monitors:
        current = get_brightness(monitor.display_num)
        if current is not None:
            print(f"Display {monitor.display_num}: {current}%")
        else:
            print(f"Display {monitor.display_num}: unable to read brightness")

    return 0


def cmd_up(args: argparse.Namespace) -> int:
    """Handle the 'up' command."""
    set_override(60)

    monitors = detect_monitors()
    if not monitors:
        print("No monitors detected", file=sys.stderr)
        return 1

    for monitor in monitors:
        current = get_brightness(monitor.display_num)
        if current is not None:
            new_brightness = min(100, current + args.amount)
            if set_brightness(monitor.display_num, new_brightness):
                print(f"Display {monitor.display_num}: {current}% -> {new_brightness}%")
            else:
                print(
                    f"Failed to adjust display {monitor.display_num}", file=sys.stderr
                )

    return 0


def cmd_down(args: argparse.Namespace) -> int:
    """Handle the 'down' command."""
    set_override(60)

    monitors = detect_monitors()
    if not monitors:
        print("No monitors detected", file=sys.stderr)
        return 1

    for monitor in monitors:
        current = get_brightness(monitor.display_num)
        if current is not None:
            new_brightness = max(0, current - args.amount)
            if set_brightness(monitor.display_num, new_brightness):
                print(f"Display {monitor.display_num}: {current}% -> {new_brightness}%")
            else:
                print(
                    f"Failed to adjust display {monitor.display_num}", file=sys.stderr
                )

    return 0


def cmd_status(args: argparse.Namespace) -> int:
    """Handle the 'status' command."""
    print("=== DDC Brightness Status ===")

    state_file = get_state_file()
    if state_file.exists():
        try:
            state = json.loads(state_file.read_text())
            print(f"Last update: {state.get('timestamp', 'unknown')}")
            print(f"Base brightness: {state.get('base_brightness', '?')}%")
            monitors = state.get("monitors", {})
            if monitors:
                print("Monitor states:")
                for display, brightness in monitors.items():
                    print(f"  Display {display}: {brightness}%")
        except Exception as e:
            print(f"Error reading state: {e}")
    else:
        print("No state file found (daemon may not be running)")

    print()

    override_remaining = get_override_remaining()
    if override_remaining is not None:
        print(f"Manual override: ACTIVE ({override_remaining} minutes remaining)")
    else:
        print("Manual override: inactive")

    return 0


def cmd_override(args: argparse.Namespace) -> int:
    """Handle the 'override' command."""
    set_override(args.minutes)
    print(f"Auto-adjust paused for {args.minutes} minutes")
    return 0


def cmd_resume(args: argparse.Namespace) -> int:
    """Handle the 'resume' command."""
    clear_override()
    print("Auto-adjust resumed")
    return 0


def cmd_detect(args: argparse.Namespace) -> int:
    """Handle the 'detect' command."""
    # Use full ddcutil output for detailed info
    try:
        result = subprocess.run(
            ["ddcutil", "detect"],
            timeout=60,
        )
        return result.returncode
    except subprocess.TimeoutExpired:
        print("Error: ddcutil detect timed out", file=sys.stderr)
        return 1


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="DDC/CI Monitor Brightness Control",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  ddc-brightness-ctl get                    Get current brightness of all monitors
  ddc-brightness-ctl set 70                 Set all monitors to 70%
  ddc-brightness-ctl set --display 1 80     Set display 1 to 80%
  ddc-brightness-ctl up 10                  Increase brightness by 10%
  ddc-brightness-ctl down 10                Decrease brightness by 10%
  ddc-brightness-ctl override 120           Pause auto-adjust for 2 hours
  ddc-brightness-ctl resume                 Resume auto-adjust
  ddc-brightness-ctl status                 Show daemon status
  ddc-brightness-ctl detect                 List detected monitors
        """,
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # set command
    set_parser = subparsers.add_parser("set", help="Set brightness")
    _ = set_parser.add_argument("brightness", type=int, help="Brightness level (0-100)")
    _ = set_parser.add_argument(
        "--display", "-d", type=int, help="Specific display number (optional)"
    )
    set_parser.set_defaults(func=cmd_set)

    # get command
    get_parser = subparsers.add_parser("get", help="Get current brightness")
    get_parser.set_defaults(func=cmd_get)

    # up command
    up_parser = subparsers.add_parser("up", help="Increase brightness")
    _ = up_parser.add_argument(
        "amount",
        type=int,
        nargs="?",
        default=10,
        help="Amount to increase (default: 10)",
    )
    up_parser.set_defaults(func=cmd_up)

    # down command
    down_parser = subparsers.add_parser("down", help="Decrease brightness")
    _ = down_parser.add_argument(
        "amount",
        type=int,
        nargs="?",
        default=10,
        help="Amount to decrease (default: 10)",
    )
    down_parser.set_defaults(func=cmd_down)

    # status command
    status_parser = subparsers.add_parser("status", help="Show daemon status")
    status_parser.set_defaults(func=cmd_status)

    # override command
    override_parser = subparsers.add_parser("override", help="Pause auto-adjustment")
    _ = override_parser.add_argument(
        "minutes",
        type=int,
        nargs="?",
        default=60,
        help="Duration in minutes (default: 60)",
    )
    override_parser.set_defaults(func=cmd_override)

    # resume command
    resume_parser = subparsers.add_parser("resume", help="Resume auto-adjustment")
    resume_parser.set_defaults(func=cmd_resume)

    # detect command
    detect_parser = subparsers.add_parser("detect", help="List detected monitors")
    detect_parser.set_defaults(func=cmd_detect)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
