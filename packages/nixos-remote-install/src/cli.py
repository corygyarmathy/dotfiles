#!/usr/bin/env python3
"""
nixos-remote-install - Automated NixOS installation using nixos-anywhere.

This tool handles the complete installation workflow including:
- SSH connectivity verification
- SSH host key pre-generation for sops-nix bootstrapping
- Age key derivation and .sops.yaml updates
- Secrets re-encryption
- nixos-anywhere execution with proper configuration
"""

import argparse
import sys
from pathlib import Path
from typing import NoReturn

from config import InstallConfig
from installer import NixOSInstaller
from logger import LogLevel, Logger


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        prog="nixos-remote-install",
        description="Automated NixOS installation using nixos-anywhere with sops-nix support",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Install homelab02 to machine at 192.168.1.100
    nixos-remote-install homelab02 192.168.1.100 --disk /dev/nvme0n1

    # Install with explicit SSH user and port
    nixos-remote-install homelab02 192.168.1.100 --user root --port 2222 --disk /dev/sda

    # Dry run to see what would happen
    nixos-remote-install homelab02 192.168.1.100 --disk /dev/nvme0n1 --dry-run

Prerequisites:
    1. Target machine booted from NixOS installer (or any Linux with SSH)
    2. SSH access enabled (run 'sudo passwd nixos' on installer first)
    3. Your dotfiles repo with flake.nix in current directory (or use --flake-dir)
    4. nix with flakes enabled
    5. Required tools: ssh, ssh-keygen, ssh-to-age, sops
        """,
    )

    parser.add_argument(
        "hostname",
        help="NixOS configuration name (e.g., homelab02)",
    )

    parser.add_argument(
        "target",
        help="IP address or hostname of the target machine",
    )

    parser.add_argument(
        "--disk",
        dest="disk",
        help="Target disk device (e.g., /dev/nvme0n1). If not specified, will prompt.",
    )

    parser.add_argument(
        "--user",
        default="nixos",
        help="SSH user on target (default: nixos for installer)",
    )

    parser.add_argument(
        "--port",
        type=int,
        default=22,
        help="SSH port (default: 22)",
    )

    parser.add_argument(
        "--flake-dir",
        type=Path,
        default=Path.cwd(),
        help="Path to flake directory (default: current directory)",
    )

    parser.add_argument(
        "--temp-dir",
        type=Path,
        default=None,
        help="Directory for temporary files (default: .install-temp in flake dir)",
    )

    parser.add_argument(
        "--skip-rekey",
        action="store_true",
        help="Skip sops secrets re-encryption",
    )

    parser.add_argument(
        "--skip-sops",
        action="store_true",
        help="Skip all sops-related steps (key generation, .sops.yaml update, rekeying)",
    )

    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without executing",
    )

    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Enable verbose output",
    )

    parser.add_argument(
        "--yes",
        "-y",
        action="store_true",
        help="Skip confirmation prompts (use with caution)",
    )

    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> NoReturn:
    """Main entry point."""
    args = parse_args(argv)

    # Set up logging
    log_level = LogLevel.DEBUG if args.verbose else LogLevel.INFO
    logger = Logger(level=log_level)

    # Build configuration
    config = InstallConfig(
        hostname=args.hostname,
        target=args.target,
        disk=args.disk,
        ssh_user=args.user,
        ssh_port=args.port,
        flake_dir=args.flake_dir.resolve(),
        temp_dir=args.temp_dir.resolve() if args.temp_dir else None,
        skip_rekey=args.skip_rekey,
        skip_sops=args.skip_sops,
        dry_run=args.dry_run,
        auto_confirm=args.yes,
    )

    # Print banner
    logger.banner(
        "NixOS Remote Installation",
        [
            f"Host:   {config.hostname}",
            f"Target: {config.target}",
            f"User:   {config.ssh_user}",
            f"Port:   {config.ssh_port}",
            f"Flake:  {config.flake_dir}",
        ],
    )

    # Run installer
    installer = NixOSInstaller(config, logger)

    try:
        exit_code = installer.run()
    except KeyboardInterrupt:
        logger.warn("\nInstallation cancelled by user")
        exit_code = 130

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
