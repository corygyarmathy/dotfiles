#!/usr/bin/env python3
"""
Background build script for NixOS updates.

This script performs a low-priority background build of pending updates:
1. Runs nix build with nice/ionice for low priority
2. Stores the build path in state for fast switching later
3. Does NOT activate the build

Exit codes:
    0: Build successful or no updates pending
    1: Build failed
    2: No updates pending
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from common import (
    UpgradeStatus,
    get_flake_owner,
    load_state,
    now_iso,
    run_as_user,
    run_command,
    save_state,
    setup_logging,
)

logger = setup_logging("background_build")


def run_low_priority_build(
    flake_dir: Path,
    hostname: str,
    flake_owner: str,
    nice_level: int = 19,
    ionice_class: str = "idle",
) -> str | None:
    """
    Run a low-priority nix build.

    Args:
        flake_dir: Path to the flake directory.
        hostname: NixOS hostname.
        flake_owner: Username of the flake directory owner.
        nice_level: Nice level (0-19, higher = lower priority).
        ionice_class: IO scheduling class (idle, best-effort, realtime).

    Returns:
        Path to the built system, or None if build failed.
    """
    logger.info(f"Starting low-priority build (nice={nice_level}, ionice={ionice_class})")

    # Configure git
    run_command(
        ["git", "config", "--global", "--add", "safe.directory", str(flake_dir)],
    )

    # Ensure flake.lock has correct ownership
    flake_lock = flake_dir / "flake.lock"
    if flake_lock.exists():
        run_command(["chown", f"{flake_owner}:{flake_owner}", str(flake_lock)])

    # Update flake inputs first (as flake owner)
    logger.info("Updating flake inputs...")
    result = run_as_user(
        ["nix", "flake", "update"],
        flake_owner,
        cwd=flake_dir,
        timeout=600,
    )

    if not result.success:
        logger.error(f"Flake update failed: {result.stderr}")
        return None

    # Build with nice and ionice for low priority
    # Map ionice class names to numbers
    ionice_classes = {"idle": "3", "best-effort": "2", "realtime": "1"}
    ionice_class_num = ionice_classes.get(ionice_class, "3")

    build_cmd = [
        "nice",
        "-n",
        str(nice_level),
        "ionice",
        "-c",
        ionice_class_num,
        "nix",
        "build",
        f".#nixosConfigurations.{hostname}.config.system.build.toplevel",
        "--no-link",
        "--print-out-paths",
    ]

    logger.info("Building system...")
    result = run_command(
        build_cmd,
        cwd=flake_dir,
        timeout=7200,  # 2 hours for background build
    )

    if not result.success:
        logger.error(f"Build failed: {result.stderr}")
        return None

    # Extract build path
    build_path = result.stdout.strip().split("\n")[-1]
    if not build_path.startswith("/nix/store/"):
        logger.error(f"Invalid build path: {build_path}")
        return None

    logger.info(f"Build complete: {build_path}")
    return build_path


def main() -> int:
    """Main entry point."""
    import argparse

    parser = argparse.ArgumentParser(description="Background build for NixOS updates")
    parser.add_argument(
        "--flake-dir",
        type=Path,
        required=True,
        help="Path to the flake directory",
    )
    parser.add_argument(
        "--hostname",
        required=True,
        help="NixOS hostname",
    )
    parser.add_argument(
        "--nice",
        type=int,
        default=19,
        help="Nice level (0-19, default: 19)",
    )
    parser.add_argument(
        "--ionice",
        choices=["idle", "best-effort", "realtime"],
        default="idle",
        help="IO scheduling class (default: idle)",
    )
    args = parser.parse_args()

    flake_dir = args.flake_dir.resolve()

    if not flake_dir.is_dir():
        logger.error(f"Flake directory does not exist: {flake_dir}")
        return 1

    # Load state
    state = load_state()

    # Check if there are pending updates
    if not state.has_pending_updates():
        logger.info("No pending updates, skipping build")
        return 2

    # Check if build is already complete
    if state.build_complete and state.build_path:
        if Path(state.build_path).exists():
            logger.info(f"Build already complete: {state.build_path}")
            return 0

    # Update state to building
    state.status = UpgradeStatus.BUILDING
    state.error_message = None
    save_state(state)

    try:
        flake_owner, _ = get_flake_owner(flake_dir)

        build_path = run_low_priority_build(
            flake_dir,
            args.hostname,
            flake_owner,
            nice_level=args.nice,
            ionice_class=args.ionice,
        )

        if build_path:
            state.build_complete = True
            state.build_path = build_path
            state.status = UpgradeStatus.IDLE
            save_state(state)
            logger.info("Background build completed successfully")
            return 0
        else:
            state.status = UpgradeStatus.ERROR
            state.error_message = "Background build failed"
            save_state(state)
            return 1

    except Exception as e:
        logger.exception(f"Build failed: {e}")
        state.status = UpgradeStatus.ERROR
        state.error_message = str(e)
        save_state(state)
        return 1


if __name__ == "__main__":
    sys.exit(main())
