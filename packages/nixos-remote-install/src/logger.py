"""Logging utilities with colored output."""

from __future__ import annotations

import sys
from enum import IntEnum
from typing import TextIO


class LogLevel(IntEnum):
    """Log levels for filtering output."""

    DEBUG = 0
    INFO = 1
    WARN = 2
    ERROR = 3


class Colors:
    """ANSI color codes."""

    RESET = "\033[0m"
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    BLUE = "\033[0;34m"
    MAGENTA = "\033[0;35m"
    CYAN = "\033[0;36m"
    BOLD = "\033[1m"
    DIM = "\033[2m"


class Logger:
    """Simple logger with colored output and level filtering."""

    def __init__(
        self,
        level: LogLevel = LogLevel.INFO,
        stream: TextIO = sys.stderr,
        use_color: bool | None = None,
    ) -> None:
        """
        Initialise the logger.

        Args:
            level: Minimum log level to display
            stream: Output stream (default: stderr)
            use_color: Force color on/off, or None for auto-detect
        """
        self.level = level
        self.stream = stream

        if use_color is None:
            self.use_color = hasattr(stream, "isatty") and stream.isatty()
        else:
            self.use_color = use_color

    def _colorize(self, text: str, color: str) -> str:
        """Apply color to text if colors are enabled."""
        if self.use_color:
            return f"{color}{text}{Colors.RESET}"
        return text

    def _log(self, level: LogLevel, prefix: str, color: str, message: str) -> None:
        """Internal logging method."""
        if level >= self.level:
            colored_prefix = self._colorize(f"[{prefix}]", color)
            print(f"{colored_prefix} {message}", file=self.stream)

    def debug(self, message: str) -> None:
        """Log a debug message."""
        self._log(LogLevel.DEBUG, "DEBUG", Colors.DIM, message)

    def info(self, message: str) -> None:
        """Log an info message."""
        self._log(LogLevel.INFO, "INFO", Colors.BLUE, message)

    def success(self, message: str) -> None:
        """Log a success message."""
        self._log(LogLevel.INFO, "SUCCESS", Colors.GREEN, message)

    def warn(self, message: str) -> None:
        """Log a warning message."""
        self._log(LogLevel.WARN, "WARN", Colors.YELLOW, message)

    def error(self, message: str) -> None:
        """Log an error message."""
        self._log(LogLevel.ERROR, "ERROR", Colors.RED, message)

    def step(self, message: str) -> None:
        """Log a step/action message."""
        arrow = self._colorize("==>", Colors.CYAN)
        print(f"{arrow} {message}", file=self.stream)

    def substep(self, message: str) -> None:
        """Log a substep message."""
        arrow = self._colorize("  ->", Colors.DIM)
        print(f"{arrow} {message}", file=self.stream)

    def banner(self, title: str, details: list[str] | None = None) -> None:
        """Print a formatted banner."""
        width = 50
        border = "=" * width

        print(file=self.stream)
        print(self._colorize(border, Colors.BOLD), file=self.stream)
        print(
            self._colorize(f" {title.center(width - 2)}", Colors.BOLD), file=self.stream
        )
        print(self._colorize(border, Colors.BOLD), file=self.stream)

        if details:
            for detail in details:
                print(f" {detail}", file=self.stream)
            print(self._colorize(border, Colors.BOLD), file=self.stream)

        print(file=self.stream)

    def prompt(self, message: str, default: str | None = None) -> str:
        """
        Prompt the user for input.

        Args:
            message: Prompt message
            default: Default value if user presses Enter

        Returns:
            User input or default value
        """
        if default:
            prompt_text = f"{message} [{default}]: "
        else:
            prompt_text = f"{message}: "

        try:
            response = input(prompt_text).strip()
            return response if response else (default or "")
        except EOFError:
            return default or ""

    def confirm(self, message: str, default: bool = False) -> bool:
        """
        Ask for user confirmation.

        Args:
            message: Confirmation message
            default: Default value if user presses Enter

        Returns:
            True if confirmed, False otherwise
        """
        if default:
            prompt_suffix = "[Y/n]"
        else:
            prompt_suffix = "[y/N]"

        response = self.prompt(f"{message} {prompt_suffix}")

        if not response:
            return default

        return response.lower() in ("y", "yes")

    def confirm_dangerous(self, message: str) -> bool:
        """
        Ask for explicit confirmation of a dangerous action.

        Requires the user to type 'yes' explicitly.

        Args:
            message: Warning message

        Returns:
            True only if user types 'yes'
        """
        self.warn(message)
        response = self.prompt("Type 'yes' to confirm")
        return response.lower() == "yes"
