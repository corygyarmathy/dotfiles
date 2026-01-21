"""Command execution utilities."""

from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from logger import Logger


@dataclass
class CommandResult:
    """Result of a command execution."""

    returncode: int
    stdout: str
    stderr: str

    @property
    def success(self) -> bool:
        """Whether the command succeeded."""
        return self.returncode == 0

    @property
    def output(self) -> str:
        """Combined stdout and stderr, stripped."""
        return (self.stdout + self.stderr).strip()


class CommandRunner:
    """Utility for running shell commands."""

    def __init__(self, logger: Logger, dry_run: bool = False) -> None:
        """
        Initialise the command runner.

        Args:
            logger: Logger instance for output
            dry_run: If True, only log commands without executing
        """
        self.logger = logger
        self.dry_run = dry_run

    def run(
        self,
        cmd: list[str],
        *,
        check: bool = True,
        capture: bool = True,
        cwd: Path | None = None,
        env: dict[str, str] | None = None,
        input_text: str | None = None,
    ) -> CommandResult:
        """
        Run a command.

        Args:
            cmd: Command and arguments as a list
            check: Raise exception on non-zero exit code
            capture: Capture stdout/stderr (if False, inherits from parent)
            cwd: Working directory
            env: Environment variables (merged with current env)
            input_text: Text to send to stdin

        Returns:
            CommandResult with return code and output

        Raises:
            subprocess.CalledProcessError: If check=True and command fails
        """
        cmd_str = " ".join(cmd)
        self.logger.debug(f"Running: {cmd_str}")

        if self.dry_run:
            self.logger.info(f"[DRY RUN] Would execute: {cmd_str}")
            return CommandResult(returncode=0, stdout="", stderr="")

        try:
            result = subprocess.run(
                cmd,
                check=False,  # We handle checking ourselves
                capture_output=capture,
                text=True,
                cwd=cwd,
                env=env,
                input=input_text,
            )

            cmd_result = CommandResult(
                returncode=result.returncode,
                stdout=result.stdout if capture else "",
                stderr=result.stderr if capture else "",
            )

            if check and not cmd_result.success:
                self.logger.error(f"Command failed: {cmd_str}")
                if cmd_result.stderr:
                    self.logger.error(cmd_result.stderr)
                raise subprocess.CalledProcessError(
                    result.returncode,
                    cmd,
                    result.stdout,
                    result.stderr,
                )

            return cmd_result

        except FileNotFoundError as exc:
            self.logger.error(f"Command not found: {cmd[0]}")
            raise subprocess.CalledProcessError(127, cmd, "", str(exc)) from exc

    def run_ssh(
        self,
        target: str,
        remote_cmd: str,
        *,
        port: int = 22,
        check: bool = True,
        capture: bool = True,
        options: list[str] | None = None,
    ) -> CommandResult:
        """
        Run a command over SSH.

        Args:
            target: SSH target (user@host)
            remote_cmd: Command to run on remote host
            port: SSH port
            check: Raise exception on non-zero exit code
            capture: Capture output
            options: Additional SSH options

        Returns:
            CommandResult
        """
        cmd = ["ssh"]

        if port != 22:
            cmd.extend(["-p", str(port)])

        if options:
            cmd.extend(options)

        cmd.extend([target, remote_cmd])

        return self.run(cmd, check=check, capture=capture)

    def check_command_exists(self, command: str) -> bool:
        """Check if a command exists in PATH."""
        return shutil.which(command) is not None

    def check_ssh_connection(
        self,
        target: str,
        port: int = 22,
        timeout: int = 10,
    ) -> bool:
        """
        Check if SSH connection can be established.

        Args:
            target: SSH target (user@host)
            port: SSH port
            timeout: Connection timeout in seconds

        Returns:
            True if connection successful
        """
        try:
            result = self.run(
                [
                    "ssh",
                    "-o",
                    f"ConnectTimeout={timeout}",
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "StrictHostKeyChecking=accept-new",
                    "-p",
                    str(port),
                    target,
                    "echo ok",
                ],
                check=False,
                capture=True,
            )
            return result.success and "ok" in result.stdout
        except subprocess.CalledProcessError:
            return False
