#!/usr/bin/env python3
"""
Waybar click handler for NixOS upgrade module.

Handles left-click and right-click actions on the waybar module:
- Left-click: Apply updates / show status / view logs (depending on state)
- Right-click: Cancel build (if building)

This script is designed to be called from waybar's on-click handlers.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from common import (
    UpgradeStatus,
    load_state,
    run_command,
    save_state,
    send_notification,
    setup_logging,
)

logger = setup_logging("waybar_click")


def show_logs() -> None:
    """Open a terminal with the upgrade service logs."""
    # Try to find a terminal emulator
    terminals = ["ghostty", "alacritty", "kitty", "foot", "gnome-terminal", "konsole"]

    for term in terminals:
        result = run_command(["which", term])
        if result.success:
            terminal = term
            break
    else:
        send_notification(
            "Cannot Show Logs",
            "No terminal emulator found. Run:\njournalctl -u nixos-upgrade-* -f",
            urgency="normal",
            icon="dialog-information",
        )
        return

    # Open terminal with journalctl
    if terminal in ["ghostty", "alacritty", "kitty", "foot"]:
        _ = subprocess.Popen(
            [terminal, "-e", "journalctl", "-u", "nixos-upgrade-*", "-f", "-n", "100"],
            start_new_session=True,
        )
    elif terminal == "gnome-terminal":
        _ = subprocess.Popen(
            [terminal, "--", "journalctl", "-u", "nixos-upgrade-*", "-f", "-n", "100"],
            start_new_session=True,
        )
    elif terminal == "konsole":
        _ = subprocess.Popen(
            [terminal, "-e", "journalctl", "-u", "nixos-upgrade-*", "-f", "-n", "100"],
            start_new_session=True,
        )


def trigger_check() -> None:
    """Trigger an update check."""
    send_notification(
        "Checking for Updates",
        "Please wait...",
        urgency="low",
        icon="system-software-update",
        timeout=3000,
    )

    # Start the check service
    result = run_command(
        ["systemctl", "start", "nixos-upgrade-check.service"],
        timeout=30,
    )

    if not result.success:
        # Try with pkexec
        result = run_command(
            ["pkexec", "systemctl", "start", "nixos-upgrade-check.service"],
            timeout=30,
        )

    if not result.success:
        send_notification(
            "Check Failed",
            "Could not start update check. Check permissions.",
            urgency="normal",
            icon="dialog-error",
        )


def trigger_apply() -> None:
    """Trigger update application."""
    send_notification(
        "Applying Updates",
        "This may take several minutes...",
        urgency="low",
        icon="system-software-update",
        timeout=5000,
    )

    # Start the apply service
    result = run_command(
        ["systemctl", "start", "nixos-upgrade-apply.service"],
        timeout=30,
    )

    if not result.success:
        # Try with pkexec
        result = run_command(
            ["pkexec", "systemctl", "start", "nixos-upgrade-apply.service"],
            timeout=30,
        )

    if not result.success:
        send_notification(
            "Apply Failed",
            "Could not start update application. Check permissions.",
            urgency="normal",
            icon="dialog-error",
        )


def trigger_reboot() -> None:
    """Trigger system reboot after user confirmation."""
    # Use a simple notification with action
    # Since we can't easily do interactive notifications in Python,
    # just reboot directly (user clicked the reboot-needed icon)
    send_notification(
        "Rebooting System",
        "System will reboot in 10 seconds...",
        urgency="critical",
        icon="system-reboot",
        timeout=10000,
    )

    # Give user time to cancel (they can close the notification)
    import time

    time.sleep(10)

    _ = run_command(["systemctl", "reboot"])


def cancel_build() -> None:
    """Cancel a running background build."""
    result = run_command(
        ["systemctl", "stop", "nixos-upgrade-build.service"],
        timeout=30,
    )

    if result.success:
        state = load_state()
        state.status = UpgradeStatus.IDLE
        save_state(state)

        send_notification(
            "Build Cancelled",
            "Background build has been stopped.",
            urgency="low",
            icon="dialog-information",
        )
    else:
        send_notification(
            "Cancel Failed",
            "Could not stop background build.",
            urgency="normal",
            icon="dialog-error",
        )


def show_status() -> None:
    """Show current status via notification."""
    state = load_state()

    if state.status == UpgradeStatus.BUILDING:
        send_notification(
            "Building Updates",
            "Background build in progress...\nRight-click to cancel.",
            urgency="low",
            icon="system-software-update",
            timeout=5000,
        )
    elif state.status == UpgradeStatus.APPLYING:
        send_notification(
            "Applying Updates",
            "Updates are being applied...\nPlease wait.",
            urgency="low",
            icon="system-software-update",
            timeout=5000,
        )
    elif state.status == UpgradeStatus.CHECKING:
        send_notification(
            "Checking for Updates",
            "Update check in progress...",
            urgency="low",
            icon="system-software-update",
            timeout=3000,
        )


def handle_left_click() -> None:
    """Handle left-click on waybar module."""
    state = load_state()

    if state.status == UpgradeStatus.ERROR:
        # Error state: show logs
        show_logs()

    elif state.status in (
        UpgradeStatus.BUILDING,
        UpgradeStatus.APPLYING,
        UpgradeStatus.CHECKING,
    ):
        # In progress: show status
        show_status()

    elif state.has_pending_updates():
        if state.requires_reboot():
            # Updates pending that need reboot - apply and schedule reboot
            trigger_apply()
        else:
            # Normal updates - apply
            trigger_apply()

    else:
        # No updates: trigger check
        trigger_check()


def handle_right_click() -> None:
    """Handle right-click on waybar module."""
    state = load_state()

    if state.status == UpgradeStatus.BUILDING:
        # Cancel build
        cancel_build()
    elif state.status == UpgradeStatus.ERROR:
        # Clear error state
        state.status = UpgradeStatus.IDLE
        state.error_message = None
        save_state(state)
        send_notification(
            "Error Cleared",
            "Error state has been cleared.",
            urgency="low",
            icon="dialog-information",
            timeout=3000,
        )
    else:
        # Show status or do nothing
        show_status()


def main() -> int:
    """Main entry point."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Waybar click handler for NixOS upgrades"
    )
    _ = parser.add_argument(
        "--button",
        choices=["left", "right", "middle"],
        default="left",
        help="Which button was clicked",
    )
    args = parser.parse_args()

    if args.button == "left":
        handle_left_click()
    elif args.button == "right":
        handle_right_click()
    elif args.button == "middle":
        # Middle click: show logs
        show_logs()

    return 0


if __name__ == "__main__":
    sys.exit(main())
