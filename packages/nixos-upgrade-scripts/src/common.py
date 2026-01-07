#!/usr/bin/env python3
"""
Common utilities for NixOS upgrade scripts.

This module provides shared functionality for state management,
logging, and subprocess execution.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any


# Constants
def get_state_dir() -> Path:
    """Get state directory, respecting environment override."""
    return Path(
        os.environ.get("NIXOS_UPGRADE_STATE_DIR", "/var/lib/nixos-auto-upgrade")
    )


def get_state_file() -> Path:
    """Get state file path."""
    return get_state_dir() / "state.json"


STATE_DIR: Path = get_state_dir()
STATE_FILE: Path = get_state_file()
LOG_FORMAT = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"


class UpgradeStatus(Enum):
    """Possible states of the upgrade system."""

    IDLE = "idle"
    CHECKING = "checking"
    BUILDING = "building"
    APPLYING = "applying"
    ERROR = "error"


@dataclass
class PendingNixUpdates:
    """Information about pending Nix package updates."""

    count: int = 0
    upgraded: int = 0
    added: int = 0
    removed: int = 0
    summary: str = ""
    requires_reboot: bool = False
    diff: str = ""
    notable_packages: list[str] = field(default_factory=list)


@dataclass
class PendingFirmwareUpdates:
    """Information about pending firmware updates."""

    count: int = 0
    devices: list[str] = field(default_factory=list)
    requires_reboot: bool = True  # Firmware updates almost always need reboot


@dataclass
class UpgradeState:
    """Complete state of the upgrade system."""

    status: UpgradeStatus = UpgradeStatus.IDLE
    last_check: str | None = None
    last_apply: str | None = None
    pending_nix: PendingNixUpdates | None = None
    pending_firmware: PendingFirmwareUpdates | None = None
    error_message: str | None = None
    build_complete: bool = False
    build_path: str | None = None

    def to_dict(self) -> dict[str, Any]:
        """Convert state to dictionary for JSON serialization."""
        return {
            "status": self.status.value,
            "last_check": self.last_check,
            "last_apply": self.last_apply,
            "pending_nix": (
                {
                    "count": self.pending_nix.count,
                    "upgraded": self.pending_nix.upgraded,
                    "added": self.pending_nix.added,
                    "removed": self.pending_nix.removed,
                    "summary": self.pending_nix.summary,
                    "requires_reboot": self.pending_nix.requires_reboot,
                    "diff": self.pending_nix.diff,
                    "notable_packages": self.pending_nix.notable_packages,
                }
                if self.pending_nix
                else None
            ),
            "pending_firmware": (
                {
                    "count": self.pending_firmware.count,
                    "devices": self.pending_firmware.devices,
                    "requires_reboot": self.pending_firmware.requires_reboot,
                }
                if self.pending_firmware
                else None
            ),
            "error_message": self.error_message,
            "build_complete": self.build_complete,
            "build_path": self.build_path,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> UpgradeState:
        """Create state from dictionary."""
        state = cls()
        state.status = UpgradeStatus(data.get("status", "idle"))
        state.last_check = data.get("last_check")
        state.last_apply = data.get("last_apply")
        state.error_message = data.get("error_message")
        state.build_complete = data.get("build_complete", False)
        state.build_path = data.get("build_path")

        if data.get("pending_nix"):
            nix = data["pending_nix"]
            state.pending_nix = PendingNixUpdates(
                count=nix.get("count", 0),
                upgraded=nix.get("upgraded", 0),
                added=nix.get("added", 0),
                removed=nix.get("removed", 0),
                summary=nix.get("summary", ""),
                requires_reboot=nix.get("requires_reboot", False),
                diff=nix.get("diff", ""),
                notable_packages=nix.get("notable_packages", []),
            )

        if data.get("pending_firmware"):
            fw = data["pending_firmware"]
            state.pending_firmware = PendingFirmwareUpdates(
                count=fw.get("count", 0),
                devices=fw.get("devices", []),
                requires_reboot=fw.get("requires_reboot", True),
            )

        return state

    def has_pending_updates(self) -> bool:
        """Check if there are any pending updates."""
        has_nix: bool = self.pending_nix is not None and self.pending_nix.count > 0
        has_firmware: bool = (
            self.pending_firmware is not None and self.pending_firmware.count > 0
        )
        return has_nix or has_firmware

    def requires_reboot(self) -> bool:
        """Check if pending updates require a reboot."""
        nix_reboot: bool = (
            self.pending_nix is not None and self.pending_nix.requires_reboot
        )
        fw_reboot: bool = (
            self.pending_firmware is not None
            and self.pending_firmware.count > 0
            and self.pending_firmware.requires_reboot
        )
        return nix_reboot or fw_reboot

    def get_summary(self) -> str:
        """Get a human-readable summary of pending updates."""
        parts: list[str] = []

        if self.pending_nix and self.pending_nix.count > 0:
            parts.append(
                self.pending_nix.summary or f"{self.pending_nix.count} packages"
            )

        if self.pending_firmware and self.pending_firmware.count > 0:
            parts.append(f"{self.pending_firmware.count} firmware")

        if not parts:
            return "No updates"

        summary: str = ", ".join(parts)
        if self.requires_reboot():
            summary += " (reboot required)"
        return summary


def setup_logging(name: str, level: int = logging.INFO) -> logging.Logger:
    """Set up logging for a script."""
    logger: logging.Logger = logging.getLogger(name)
    logger.setLevel(level)

    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter(LOG_FORMAT))
    logger.addHandler(handler)

    return logger


def load_state() -> UpgradeState:
    """Load state from the state file."""
    if not STATE_FILE.exists():
        return UpgradeState()

    try:
        with open(STATE_FILE, "r") as f:
            data = json.load(f)
        return UpgradeState.from_dict(data)
    except (json.JSONDecodeError, OSError):
        return UpgradeState()


def save_state(state: UpgradeState) -> None:
    """Save state to the state file."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    with open(STATE_FILE, "w") as f:
        json.dump(state.to_dict(), f, indent=2)

    # Ensure the file is readable by all and writable by group (for waybar click handler)
    os.chmod(STATE_FILE, 0o664)


def now_iso() -> str:
    """Get current time in ISO format."""
    return datetime.now(timezone.utc).isoformat()


def format_timestamp_for_display(iso_timestamp: str) -> str:
    """Convert UTC ISO timestamp to local time for display."""
    dt: datetime = datetime.fromisoformat(iso_timestamp)
    local_dt: datetime = dt.astimezone()  # converts to system local timezone
    return local_dt.strftime("%Y-%m-%d %H:%M %Z")


@dataclass
class CommandResult:
    """Result of a subprocess command."""

    returncode: int
    stdout: str
    stderr: str

    @property
    def success(self) -> bool:
        """Check if the command succeeded."""
        return self.returncode == 0


def run_command(
    args: list[str],
    *,
    cwd: Path | str | None = None,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
    capture_output: bool = True,
    check: bool = False,
) -> CommandResult:
    """
    Run a command and return the result.

    Args:
        args: Command and arguments to run.
        cwd: Working directory for the command.
        env: Environment variables (merged with current env).
        timeout: Timeout in seconds.
        capture_output: Whether to capture stdout/stderr.
        check: Whether to raise an exception on non-zero exit.

    Returns:
        CommandResult with returncode, stdout, and stderr.

    Raises:
        subprocess.CalledProcessError: If check=True and command fails.
        subprocess.TimeoutExpired: If timeout is exceeded.
    """
    full_env: dict[str, str] = os.environ.copy()
    if env:
        full_env.update(env)

    result: subprocess.CompletedProcess[str] = subprocess.run(
        args,
        cwd=cwd,
        env=full_env,
        timeout=timeout,
        capture_output=capture_output,
        text=True,
    )

    cmd_result: CommandResult = CommandResult(
        returncode=result.returncode,
        stdout=result.stdout if capture_output else "",
        stderr=result.stderr if capture_output else "",
    )

    if check and not cmd_result.success:
        raise subprocess.CalledProcessError(
            returncode=result.returncode,
            cmd=args,
            output=result.stdout,
            stderr=result.stderr,
        )

    return cmd_result


def run_as_user(
    args: list[str],
    user: str,
    *,
    cwd: Path | str | None = None,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
) -> CommandResult:
    """Run a command as a specific user using sudo."""
    sudo_args: list[str] = ["sudo", "-u", user]
    if env:
        for key, value in env.items():
            sudo_args.extend([f"{key}={value}"])
    sudo_args.extend(args)
    return run_command(sudo_args, cwd=cwd, timeout=timeout)


def get_flake_owner(flake_dir: Path) -> tuple[str, str]:
    """Get the owner and group of the flake directory."""
    import stat as stat_module
    import pwd
    import grp

    stat_info = flake_dir.stat()
    owner: str = pwd.getpwuid(stat_info.st_uid).pw_name
    group: str = grp.getgrgid(stat_info.st_gid).gr_name
    return owner, group


def send_notification(
    title: str,
    body: str,
    *,
    urgency: str = "normal",
    icon: str | None = None,
    timeout: int | None = None,
) -> None:
    """
    Send a desktop notification using notify-send.

    Args:
        title: Notification title.
        body: Notification body.
        urgency: Urgency level (low, normal, critical).
        icon: Icon name or path.
        timeout: Timeout in milliseconds (0 for no timeout).
    """
    args: list[str] = ["notify-send", f"--urgency={urgency}"]

    if icon:
        args.extend(["--icon", icon])
    if timeout is not None:
        args.extend(["--expire-time", str(timeout)])

    args.extend([title, body])

    try:
        _ = run_command(args, check=False)
    except FileNotFoundError:
        # notify-send not available, silently ignore
        pass


def is_graphical_session_active() -> bool:
    """Check if a graphical session is currently active."""
    # Check if graphical-session.target is active for any user
    result: CommandResult = run_command(
        ["systemctl", "--user", "is-active", "graphical-session.target"],
    )
    if result.success and "active" in result.stdout:
        return True

    return False


def detect_reboot_required() -> bool:
    """
    Check if a reboot is required by comparing booted and current kernels.

    Returns:
        True if the current kernel differs from the booted kernel.
    """
    booted_kernel: Path = Path("/run/booted-system/kernel")
    current_kernel: Path = Path("/run/current-system/kernel")

    if not booted_kernel.exists() or not current_kernel.exists():
        return False

    try:
        booted: Path = booted_kernel.resolve()
        current: Path = current_kernel.resolve()
        return booted != current
    except OSError:
        return False


def detect_switch_inhibitors(new_system_path: str) -> tuple[bool, list[str]]:
    """
    Check if switching to a new system would trigger switch inhibitors.

    Args:
        new_system_path: Path to the new system in /nix/store.

    Returns:
        Tuple of (has_inhibitors, list of inhibitor package names).
    """
    current_inhibitors = Path("/run/current-system/switch-inhibitors")
    new_inhibitors = Path(new_system_path) / "switch-inhibitors"

    # If neither has inhibitors, we're fine
    if not current_inhibitors.exists() and not new_inhibitors.exists():
        return False, []

    # Read current inhibitors
    current_set: set[str] = set()
    if current_inhibitors.exists():
        current_set = set(current_inhibitors.read_text().strip().split("\n"))
        current_set.discard("")

    # Read new inhibitors
    new_set: set[str] = set()
    if new_inhibitors.exists():
        new_set = set(new_inhibitors.read_text().strip().split("\n"))
        new_set.discard("")

    # Check for differences - if any inhibitor package changed, we need boot
    if current_set != new_set:
        # Find which packages differ
        changed = current_set.symmetric_difference(new_set)
        return True, list(changed)

    return False, []
