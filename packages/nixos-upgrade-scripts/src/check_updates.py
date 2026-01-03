#!/usr/bin/env python3
"""
Check for available NixOS and firmware updates.

This script checks for updates without applying them:
1. Updates flake inputs (temporarily)
2. Builds to see what would change
3. Checks for firmware updates via fwupd
4. Updates state file with results
5. Restores flake.lock to original state

Exit codes:
    0: Success (updates available or no updates)
    1: Error during check
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from common import (
    CommandResult,
    PendingFirmwareUpdates,
    PendingNixUpdates,
    UpgradeState,
    UpgradeStatus,
    get_flake_owner,
    load_state,
    now_iso,
    run_as_user,
    run_command,
    save_state,
    setup_logging,
)

logger = setup_logging("check_updates")

# Notable packages that warrant highlighting
NOTABLE_PACKAGE_PATTERNS = [
    r"linux-\d",
    r"systemd",
    r"openssl",
    r"openssh",
    r"sudo",
    r"polkit",
    r"kernel",
    r"firmware",
    r"glibc",
    r"mesa",
    r"nvidia",
]


def check_nix_updates(
    flake_dir: Path, hostname: str, flake_owner: str
) -> PendingNixUpdates | None:
    """
    Check for Nix package updates.

    Args:
        flake_dir: Path to the flake directory.
        hostname: NixOS hostname for the configuration.
        flake_owner: Username of the flake directory owner.

    Returns:
        PendingNixUpdates if updates are available, None otherwise.
    """
    logger.info("Checking for Nix updates...")

    # Configure git to allow operations on user-owned repo
    _ = run_command(
        ["git", "config", "--global", "--add", "safe.directory", str(flake_dir)],
    )

    # Ensure flake.lock has correct ownership and is clean
    flake_lock = flake_dir / "flake.lock"
    if flake_lock.exists():
        _ = run_command(["chown", f"{flake_owner}:{flake_owner}", str(flake_lock)])

    # Update flake inputs as the flake owner
    logger.info("Updating flake inputs...")
    result = run_as_user(
        ["nix", "flake", "update"],
        flake_owner,
        cwd=flake_dir,
        timeout=600,  # 10 minutes
    )

    if not result.success:
        logger.error(f"Flake update failed: {result.stderr}")
        raise RuntimeError(f"Flake update failed: {result.stderr}")

    # Check if flake.lock changed
    diff_result = run_command(["git", "diff", "--quiet", "flake.lock"], cwd=flake_dir)
    if diff_result.success:
        logger.info("No flake input changes detected")
        return None

    logger.info("Flake inputs changed, building to check package changes...")

    # Get current system path
    current_system = Path("/run/current-system").resolve()
    logger.info(f"Current system: {current_system}")

    # Build new system to see changes
    build_result = run_command(
        [
            "nix",
            "build",
            f".#nixosConfigurations.{hostname}.config.system.build.toplevel",
            "--no-link",
            "--print-out-paths",
        ],
        cwd=flake_dir,
        timeout=1800,  # 30 minutes
    )

    if not build_result.success:
        logger.warning(f"Build failed: {build_result.stderr}")
        # Return partial info - updates are available but we can't build
        return PendingNixUpdates(
            count=1,
            summary="Updates available (build preview failed)",
            diff=build_result.stderr[:1000],  # Truncate error output
        )

    # Extract new system path
    new_system_path = build_result.stdout.strip().split("\n")[-1]
    if not new_system_path.startswith("/nix/store/"):
        logger.warning(f"Could not parse new system path: {build_result.stdout}")
        return PendingNixUpdates(count=1, summary="Updates available (details pending)")

    logger.info(f"New system: {new_system_path}")

    # Generate diff using nvd
    nvd_result = run_command(
        ["nvd", "diff", str(current_system), new_system_path],
        timeout=60,
    )

    diff_output = nvd_result.stdout if nvd_result.success else ""

    # Parse diff output - nvd uses [U.], [U*], [C.], [C*], [A.], [R.] etc.
    upgraded = len(re.findall(r"^\[U[.*]\]", diff_output, re.MULTILINE))
    added = len(re.findall(r"^\[A[.*]\]", diff_output, re.MULTILINE))
    removed = len(re.findall(r"^\[R[.*]\]", diff_output, re.MULTILINE))
    changed = len(re.findall(r"^\[C[.*]\]", diff_output, re.MULTILINE))
    upgraded += changed  # Count changed packages as upgrades

    total = upgraded + added + removed
    if total == 0:
        logger.info("Flake inputs updated but no package changes")
        return None

    # Check for notable packages
    notable: list[str] = []
    for pattern in NOTABLE_PACKAGE_PATTERNS:
        matches = re.findall(
            rf"^\[U[.*]\].*{pattern}.*$", diff_output, re.MULTILINE | re.IGNORECASE
        )
        notable.extend(matches[:3])  # Limit per pattern

    # Check if kernel changed (indicates reboot needed)
    requires_reboot = bool(re.search(r"\[U[.*]\].*linux-\d.*->", diff_output))

    summary = f"{upgraded} updated, {added} added, {removed} removed"

    logger.info(f"Found updates: {summary}")

    return PendingNixUpdates(
        count=total,
        upgraded=upgraded,
        added=added,
        removed=removed,
        summary=summary,
        requires_reboot=requires_reboot,
        diff=diff_output,
        notable_packages=notable[:10],  # Limit total notable packages
    )


def check_firmware_updates() -> PendingFirmwareUpdates | None:
    """
    Check for firmware updates via fwupd.

    Returns:
        PendingFirmwareUpdates if updates are available, None otherwise.
    """
    logger.info("Checking for firmware updates...")

    result = run_command(
        ["fwupdmgr", "get-updates", "--json"],
        timeout=120,
    )

    if not result.success:
        # fwupdmgr returns non-zero if no updates available
        if (
            "No updates available" in result.stderr
            or "no available firmware" in result.stderr.lower()
        ):
            logger.info("No firmware updates available")
            return None
        logger.warning(f"fwupdmgr failed: {result.stderr}")
        return None

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        logger.warning(f"Failed to parse fwupdmgr output: {result.stdout[:200]}")
        return None

    # Count devices with available updates
    devices_with_updates: list[str] = []
    for device in data.get("Devices", []):
        if device.get("Releases"):
            device_name = device.get("Name", "Unknown device")
            devices_with_updates.append(device_name)

    if not devices_with_updates:
        logger.info("No firmware updates available")
        return None

    logger.info(f"Found firmware updates for: {devices_with_updates}")

    return PendingFirmwareUpdates(
        count=len(devices_with_updates),
        devices=devices_with_updates,
        requires_reboot=True,
    )


def main() -> int:
    """Main entry point."""
    import argparse

    parser = argparse.ArgumentParser(description="Check for NixOS updates")
    _ = parser.add_argument(
        "--flake-dir",
        type=Path,
        required=True,
        help="Path to the flake directory",
    )
    _ = parser.add_argument(
        "--hostname",
        required=True,
        help="NixOS hostname",
    )
    _ = parser.add_argument(
        "--check-firmware",
        action="store_true",
        help="Also check for firmware updates",
    )
    args = parser.parse_args()

    flake_dir = args.flake_dir.resolve()
    hostname = args.hostname

    if not flake_dir.is_dir():
        logger.error(f"Flake directory does not exist: {flake_dir}")
        return 1

    # Load existing state
    state = load_state()
    state.status = UpgradeStatus.CHECKING
    state.error_message = None
    save_state(state)

    try:
        flake_owner, _ = get_flake_owner(flake_dir)
        logger.info(f"Flake owner: {flake_owner}")

        # Check Nix updates
        try:
            pending_nix = check_nix_updates(flake_dir, hostname, flake_owner)
        finally:
            # Always restore flake.lock to its original state
            logger.info("Restoring flake.lock...")
            _ = run_as_user(
                ["git", "checkout", "flake.lock"], flake_owner, cwd=flake_dir
            )
            # Fix ownership in case it was changed
            flake_lock = flake_dir / "flake.lock"
            if flake_lock.exists():
                run_command(["chown", f"{flake_owner}:{flake_owner}", str(flake_lock)])

        # Check firmware updates
        pending_firmware = None
        if args.check_firmware:
            try:
                pending_firmware = check_firmware_updates()
            except Exception as e:
                logger.warning(f"Firmware check failed: {e}")

        # Update state
        state.status = UpgradeStatus.IDLE
        state.last_check = now_iso()
        state.pending_nix = pending_nix
        state.pending_firmware = pending_firmware
        state.build_complete = False
        state.build_path = None

        if state.has_pending_updates():
            logger.info(f"Updates available: {state.get_summary()}")
        else:
            logger.info("System is up to date")

        save_state(state)
        return 0

    except Exception as e:
        logger.exception(f"Check failed: {e}")
        state.status = UpgradeStatus.ERROR
        state.error_message = str(e)
        save_state(state)
        return 1


if __name__ == "__main__":
    sys.exit(main())
