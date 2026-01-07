#!/usr/bin/env python3
"""
Apply pending NixOS and firmware updates.

This script applies updates that have been previously checked:
1. Updates flake inputs
2. Builds and switches (or builds for boot if reboot needed)
3. Commits the flake.lock changes
4. Applies firmware updates if any
5. Optionally reboots (in server mode)

Exit codes:
    0: Success
    1: Error during apply
    2: No updates pending
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from common import (
    CommandResult,
    PendingNixUpdates,
    UpgradeState,
    UpgradeStatus,
    detect_reboot_required,
    get_flake_owner,
    is_graphical_session_active,
    load_state,
    now_iso,
    run_as_user,
    run_command,
    save_state,
    send_notification,
    setup_logging,
)

logger = setup_logging("apply_updates")

# Notable packages for summary
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


def apply_nix_updates(
    flake_dir: Path,
    hostname: str,
    flake_owner: str,
    use_boot: bool = False,
    auto_push: bool = False,
    state: UpgradeState | None = None,
) -> tuple[bool, str, bool]:
    """
    Apply Nix updates.

    Args:
        flake_dir: Path to the flake directory.
        hostname: NixOS hostname.
        flake_owner: Username of the flake directory owner.
        use_boot: If True, use `nixos-rebuild boot` instead of `switch`.
        auto_push: If True, push changes to git remote.
        state: Current upgrade state (for pre-built path).

    Returns:
        Tuple of (success, summary, requires_reboot).
    """
    logger.info("Applying Nix updates...")

    # Configure git
    _ = run_command(
        ["git", "config", "--global", "--add", "safe.directory", str(flake_dir)],
    )

    # Fix ownership of flake.lock
    flake_lock: Path = flake_dir / "flake.lock"
    if flake_lock.exists():
        _ = run_command(["chown", f"{flake_owner}:{flake_owner}", str(flake_lock)])

    # Stash any local changes
    stashed = False
    diff_result: CommandResult = run_command(["git", "diff", "--quiet"], cwd=flake_dir)
    if not diff_result.success:
        logger.info("Stashing local changes...")
        result: CommandResult = run_as_user(
            ["git", "stash", "push", "-m", f"auto-upgrade-stash-{now_iso()}"],
            flake_owner,
            cwd=flake_dir,
        )
        if result.success:
            stashed = True

    def restore_stash() -> None:
        if stashed:
            _ = run_as_user(["git", "stash", "pop"], flake_owner, cwd=flake_dir)

    try:
        # Get current system for comparison
        current_system = Path("/run/current-system").resolve()

        # Update flake inputs
        logger.info("Updating flake inputs...")
        result = run_as_user(
            ["nix", "flake", "update"],
            flake_owner,
            cwd=flake_dir,
            timeout=600,
        )

        if not result.success:
            logger.error(f"Flake update failed: {result.stderr}")
            restore_stash()
            return False, "Flake update failed", False

        # Check if lock file changed
        diff_result: CommandResult = run_command(
            ["git", "diff", "--quiet", "flake.lock"], cwd=flake_dir
        )
        if diff_result.success:
            logger.info("No updates available")
            restore_stash()
            return True, "No updates available", False

        # Build new system
        logger.info("Building new system...")

        # Check if we have a pre-built path
        build_path: str | None = None
        if state and state.build_complete and state.build_path:
            if Path(state.build_path).exists():
                build_path = state.build_path
                logger.info(f"Using pre-built system: {build_path}")

        if not build_path:
            result = run_command(
                [
                    "nix",
                    "build",
                    f".#nixosConfigurations.{hostname}.config.system.build.toplevel",
                    "--no-link",
                    "--print-out-paths",
                ],
                cwd=flake_dir,
                timeout=3600,  # 1 hour
            )

            if not result.success:
                logger.error(f"Build failed: {result.stderr}")
                # Revert flake.lock
                _ = run_as_user(
                    ["git", "checkout", "flake.lock"], flake_owner, cwd=flake_dir
                )
                restore_stash()
                return False, f"Build failed: {result.stderr[:200]}", False

            build_path = result.stdout.strip().split("\n")[-1]

        # Generate diff for commit message
        nvd_result: CommandResult = run_command(
            ["nvd", "diff", str(current_system), build_path],
            timeout=60,
        )
        diff_output: str = nvd_result.stdout if nvd_result.success else ""

        # Parse changes
        upgraded: int = len(re.findall(r"^\[U[.*]\]", diff_output, re.MULTILINE))
        added: int = len(re.findall(r"^\[A[.*]\]", diff_output, re.MULTILINE))
        removed: int = len(re.findall(r"^\[R[.*]\]", diff_output, re.MULTILINE))
        changed: int = len(re.findall(r"^\[C[.*]\]", diff_output, re.MULTILINE))
        upgraded += changed

        summary = f"{upgraded} updated, {added} added, {removed} removed"

        # Check for kernel changes
        kernel_changed = bool(re.search(r"\[U[.*]\].*linux-\d.*->", diff_output))
        if kernel_changed:
            summary += " (kernel updated)"

        # Check for switch inhibitors if we weren't already planning to use boot
        if not use_boot and build_path:
            from common import detect_switch_inhibitors

            has_inhibitors, inhibitor_pkgs = detect_switch_inhibitors(build_path)
            if has_inhibitors:
                logger.info(f"Switch inhibitors detected, using boot: {inhibitor_pkgs}")
                use_boot = True

        # Create commit message
        reboot_note = " (reboot required)" if kernel_changed or use_boot else ""
        commit_msg: str = f"""chore(nix): auto-upgrade{reboot_note}

{summary}

{diff_output}

Generated: {now_iso()}"""

        # Commit the lock file
        _ = run_as_user(["git", "add", "flake.lock"], flake_owner, cwd=flake_dir)
        _ = run_as_user(
            ["git", "commit", "-m", commit_msg],
            flake_owner,
            cwd=flake_dir,
            env={
                "GIT_AUTHOR_NAME": "NixOS Auto-Upgrade",
                "GIT_AUTHOR_EMAIL": f"auto-upgrade@{hostname}.local",
                "GIT_COMMITTER_NAME": "NixOS Auto-Upgrade",
                "GIT_COMMITTER_EMAIL": f"auto-upgrade@{hostname}.local",
            },
        )

        # Apply the upgrade
        rebuild_cmd = "boot" if use_boot else "switch"
        logger.info(f"Running nixos-rebuild {rebuild_cmd}...")

        result = run_command(
            ["nixos-rebuild", rebuild_cmd, "--flake", f".#{hostname}"],
            cwd=flake_dir,
            timeout=1800,  # 30 minutes
        )

        if not result.success:
            logger.error(f"nixos-rebuild failed: {result.stderr}")
            restore_stash()
            return False, f"nixos-rebuild failed: {result.stderr[:200]}", False

        # Push if enabled
        if auto_push:
            logger.info("Pushing to remote...")
            push_result: CommandResult = run_as_user(
                ["git", "push"], flake_owner, cwd=flake_dir
            )
            if not push_result.success:
                logger.warning("Push failed - manual push required")

        restore_stash()

        # Check if reboot is needed
        requires_reboot: bool = kernel_changed or detect_reboot_required()

        logger.info(f"Nix updates applied: {summary}")
        return True, summary, requires_reboot

    except Exception as e:
        logger.exception(f"Apply failed: {e}")
        restore_stash()
        return False, str(e), False


def apply_firmware_updates() -> tuple[bool, str]:
    """
    Apply firmware updates via fwupd.

    Returns:
        Tuple of (success, message).
    """
    logger.info("Applying firmware updates...")

    # Check for updates first
    check_result: CommandResult = run_command(["fwupdmgr", "get-updates"], timeout=120)

    if "No updates available" in check_result.stderr or not check_result.success:
        logger.info("No firmware updates to apply")
        return True, "No firmware updates"

    # Apply updates (--no-reboot since we'll handle reboot ourselves)
    result: CommandResult = run_command(
        ["fwupdmgr", "update", "-y"],
        timeout=600,  # 10 minutes for firmware
    )

    if result.success:
        logger.info("Firmware updates applied")
        return True, "Firmware updates applied"
    else:
        logger.error(f"Firmware update failed: {result.stderr}")
        return False, f"Firmware update failed: {result.stderr[:200]}"


def main() -> int:
    """Main entry point."""
    import argparse

    parser = argparse.ArgumentParser(description="Apply NixOS updates")
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
        "--mode",
        choices=["desktop", "server"],
        default="desktop",
        help="Operating mode (affects reboot behavior)",
    )
    _ = parser.add_argument(
        "--apply-firmware",
        action="store_true",
        help="Also apply firmware updates",
    )
    _ = parser.add_argument(
        "--auto-push",
        action="store_true",
        help="Push changes to git remote",
    )
    _ = parser.add_argument(
        "--auto-reboot",
        action="store_true",
        help="Automatically reboot if needed (server mode)",
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
        logger.info("No pending updates")
        return 2

    # Determine if we should use boot instead of switch
    use_boot = state.requires_reboot()

    # Update state to applying
    state.status = UpgradeStatus.APPLYING
    state.error_message = None
    save_state(state)

    try:
        flake_owner, _ = get_flake_owner(flake_dir)

        # Apply Nix updates
        nix_success, nix_summary, nix_reboot = apply_nix_updates(
            flake_dir,
            args.hostname,
            flake_owner,
            use_boot=use_boot,
            auto_push=args.auto_push,
            state=state,
        )

        # Apply firmware updates if requested
        fw_success = True
        fw_message = ""
        if args.apply_firmware:
            fw_success, fw_message = apply_firmware_updates()

        # Determine overall result
        success = nix_success and fw_success
        requires_reboot = nix_reboot or (
            args.apply_firmware and fw_success and "applied" in fw_message.lower()
        )

        # Update state
        if success:
            state.status = UpgradeStatus.IDLE
            state.last_apply = now_iso()
            state.pending_nix = None
            state.pending_firmware = None
            state.build_complete = False
            state.build_path = None

            # If reboot needed, keep a record
            if requires_reboot:
                # Store reboot-pending info for desktop notification
                state.error_message = f"Reboot required: {nix_summary}"
        else:
            state.status = UpgradeStatus.ERROR
            state.error_message = nix_summary if not nix_success else fw_message

        save_state(state)

        # Handle reboot
        if success and requires_reboot:
            if args.mode == "server" and args.auto_reboot:
                # Server mode: reboot automatically
                logger.info("Rebooting system...")
                _ = run_command(["systemctl", "reboot"])
            elif args.mode == "desktop":
                # Desktop mode: notify user
                if is_graphical_session_active():
                    logger.info("Graphical session active, user will be notified")
                    send_notification(
                        "System Update Complete",
                        f"{nix_summary}\n\nReboot required to complete the update.",
                        urgency="normal",
                        icon="system-reboot",
                    )
                else:
                    # No session, could auto-reboot
                    logger.info(
                        "No graphical session, but desktop mode - not auto-rebooting"
                    )

        if success:
            logger.info(f"Updates applied successfully: {nix_summary}")
            return 0
        else:
            logger.error("Update application failed")
            return 1

    except Exception as e:
        logger.exception(f"Apply failed: {e}")
        state.status = UpgradeStatus.ERROR
        state.error_message = str(e)
        save_state(state)
        return 1


if __name__ == "__main__":
    sys.exit(main())
