"""NixOS remote installation orchestrator."""

from __future__ import annotations

import os
import shutil
import stat
from typing import TYPE_CHECKING

from commands import CommandRunner
from sops import SopsManager

if TYPE_CHECKING:
    from config import InstallConfig
    from logger import Logger


class NixOSInstaller:
    """Orchestrates the NixOS remote installation process."""

    REQUIRED_COMMANDS = [
        "nix",
        "ssh",
        "ssh-keygen",
        "sops",
        "ssh-to-age",
    ]

    def __init__(self, config: InstallConfig, logger: Logger) -> None:
        """
        Initialise the installer.

        Args:
            config: Installation configuration
            logger: Logger instance
        """
        self.config = config
        self.logger = logger
        self.runner = CommandRunner(logger, dry_run=config.dry_run)
        self.sops = SopsManager(config, self.runner, logger)

    def run(self) -> int:
        """
        Run the complete installation process.

        Returns:
            Exit code (0 for success)
        """
        try:
            self._check_dependencies()
            self._validate_host_config()
            self._check_ssh_access()
            self._select_disk()

            if not self.config.skip_sops:
                self._setup_sops_keys()

            self._prepare_extra_files()
            self._run_nixos_anywhere()
            self._cleanup()

            return 0

        except InstallationError as exc:
            self.logger.error(str(exc))
            return 1
        except KeyboardInterrupt:
            self.logger.warn("Installation cancelled")
            return 130

    def _check_dependencies(self) -> None:
        """Verify all required commands are available."""
        self.logger.step("Checking dependencies")

        missing: list[str] = []

        for cmd in self.REQUIRED_COMMANDS:
            if self.runner.check_command_exists(cmd):
                self.logger.substep(f"{cmd}: found")
            else:
                self.logger.substep(f"{cmd}: NOT FOUND")
                missing.append(cmd)

        if missing:
            raise InstallationError(
                f"Missing required commands: {', '.join(missing)}\n"
                "Run 'nix develop' to enter the dev shell with required tools"
            )

        # Check nix flakes enabled
        result = self.runner.run(
            ["nix", "--version"],
            check=False,
        )
        if not result.success:
            raise InstallationError("Nix is not working correctly")

        self.logger.success("All dependencies found")

    def _validate_host_config(self) -> None:
        """Validate the NixOS configuration for the target host."""
        self.logger.step(f"Validating configuration for '{self.config.hostname}'")

        # Check flake.nix exists
        flake_path = self.config.flake_dir / "flake.nix"
        if not flake_path.exists():
            raise InstallationError(
                f"flake.nix not found in {self.config.flake_dir}\n"
                "Run this command from your dotfiles directory"
            )

        # Check host exists in flake
        result = self.runner.run(
            ["nix", "flake", "show", str(self.config.flake_dir), "--json"],
            check=False,
        )

        if not result.success or self.config.hostname not in result.stdout:
            # Fallback to non-JSON check
            result = self.runner.run(
                ["nix", "flake", "show", str(self.config.flake_dir)],
                check=False,
            )
            if self.config.hostname not in result.stdout:
                raise InstallationError(
                    f"Host '{self.config.hostname}' not found in flake.nix\n"
                    f"Available configurations are listed in 'nix flake show'"
                )

        # Check disko configuration exists
        if not self.config.disko_config.exists():
            raise InstallationError(
                f"disko.nix not found at {self.config.disko_config}\n"
                "nixos-anywhere requires declarative disk configuration"
            )

        self.logger.success(f"Configuration valid for '{self.config.hostname}'")

    def _check_ssh_access(self) -> None:
        """Verify SSH access to the target machine."""
        self.logger.step(f"Checking SSH access to {self.config.ssh_target}")

        if self.runner.check_ssh_connection(
            self.config.ssh_target,
            port=self.config.ssh_port,
        ):
            self.logger.success("SSH access confirmed")
            return

        self.logger.warn("SSH connection failed or requires password")
        self._print_ssh_setup_instructions()

        if self.config.auto_confirm:
            raise InstallationError("SSH access required (--yes flag prevents prompts)")

        if not self.logger.confirm("Retry SSH connection?", default=True):
            raise InstallationError("SSH access is required for installation")

        # Retry
        if not self.runner.check_ssh_connection(
            self.config.ssh_target,
            port=self.config.ssh_port,
        ):
            raise InstallationError(
                "Still cannot connect via SSH. Please ensure SSH is working."
            )

        self.logger.success("SSH access confirmed")

    def _print_ssh_setup_instructions(self) -> None:
        """Print instructions for setting up SSH access."""
        print()
        self.logger.info("To enable SSH on the NixOS installer, run on the target:")
        print(f"    sudo passwd {self.config.ssh_user}")
        print()
        self.logger.info("Then add your SSH key:")
        print(
            f"    ssh-copy-id -p {self.config.ssh_port} {self.config.ssh_target}"
        )
        print()

    def _select_disk(self) -> None:
        """Select or confirm the target disk."""
        if self.config.disk:
            self.logger.step(f"Using specified disk: {self.config.disk}")
            return

        self.logger.step("Discovering available disks on target")

        result = self.runner.run_ssh(
            self.config.ssh_target,
            "lsblk -d -o NAME,SIZE,TYPE,MODEL | grep disk || true",
            port=self.config.ssh_port,
            check=False,
        )

        print()
        print("Available disks:")
        print(result.stdout if result.stdout.strip() else "  (none found)")
        print()

        # Also show /dev/disk/by-id for reliable naming
        result = self.runner.run_ssh(
            self.config.ssh_target,
            "ls -la /dev/disk/by-id/ 2>/dev/null | grep -E 'nvme|ata|scsi' | head -10 || true",
            port=self.config.ssh_port,
            check=False,
        )

        if result.stdout.strip():
            print("Disk IDs (more reliable for scripting):")
            print(result.stdout)
            print()

        if self.config.auto_confirm:
            raise InstallationError(
                "No disk specified. Use --disk flag with --yes"
            )

        disk = self.logger.prompt(
            "Enter target disk (e.g., /dev/nvme0n1 or /dev/sda)"
        )

        if not disk:
            raise InstallationError("No disk specified")

        self.config.disk = disk
        self.logger.success(f"Selected disk: {disk}")

    def _setup_sops_keys(self) -> None:
        """Generate SSH host key and set up SOPS configuration."""
        self.sops.generate_ssh_host_key()
        age_key = self.sops.derive_age_key()

        if not self.sops.update_sops_yaml(age_key):
            if self.config.auto_confirm:
                raise InstallationError(
                    ".sops.yaml needs manual update (--yes flag prevents prompts)"
                )

            self.logger.prompt("Press Enter after updating .sops.yaml")

        if not self.config.skip_rekey:
            self.sops.rekey_secrets()

    def _prepare_extra_files(self) -> None:
        """Prepare the extra-files directory with SSH host keys."""
        self.logger.step("Preparing extra files for installation")

        extra_files = self.config.extra_files_dir
        ssh_dir = extra_files / "etc" / "ssh"

        # Clean and recreate
        if extra_files.exists():
            shutil.rmtree(extra_files)

        ssh_dir.mkdir(parents=True)

        # Copy SSH host keys
        private_key = self.config.ssh_private_key
        public_key = self.config.ssh_public_key

        if not private_key.exists():
            if self.config.skip_sops:
                self.logger.warn("No SSH host key found (--skip-sops was used)")
                self.logger.warn("The system will generate its own key on first boot")
                return
            raise InstallationError(f"SSH private key not found: {private_key}")

        # Copy with correct permissions
        dest_private = ssh_dir / "ssh_host_ed25519_key"
        dest_public = ssh_dir / "ssh_host_ed25519_key.pub"

        shutil.copy2(private_key, dest_private)
        shutil.copy2(public_key, dest_public)

        # Set correct permissions
        os.chmod(dest_private, stat.S_IRUSR | stat.S_IWUSR)  # 600
        os.chmod(dest_public, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)  # 644

        self.logger.success("Extra files prepared")

    def _run_nixos_anywhere(self) -> None:
        """Execute nixos-anywhere to perform the installation."""
        self.logger.step("Preparing nixos-anywhere installation")

        if not self.config.disk:
            raise InstallationError("No disk selected")

        # Build command
        cmd = [
            "nix",
            "run",
            "github:nix-community/nixos-anywhere",
            "--",
            "--flake",
            f"{self.config.flake_dir}#{self.config.hostname}",
            "--disk",
            "main",
            self.config.disk,
        ]

        # Add extra-files if we have them
        if self.config.extra_files_dir.exists():
            cmd.extend(["--extra-files", str(self.config.extra_files_dir)])

        # Add hardware config generation
        cmd.extend([
            "--generate-hardware-config",
            "nixos-generate-config",
            str(self.config.hardware_config),
        ])

        # Add SSH port if non-standard
        if self.config.ssh_port != 22:
            cmd.extend(["--ssh-port", str(self.config.ssh_port)])

        # Add target
        cmd.append(self.config.ssh_target)

        # Print command
        print()
        self.logger.info("Will execute:")
        print(f"    {' '.join(cmd)}")
        print()

        if self.config.dry_run:
            self.logger.warn("[DRY RUN] Not executing nixos-anywhere")
            return

        # Dangerous operation - require explicit confirmation
        if not self.config.auto_confirm:
            if not self.logger.confirm_dangerous(
                f"This will ERASE ALL DATA on {self.config.disk}"
            ):
                raise InstallationError("Installation aborted by user")

        self.logger.step("Starting nixos-anywhere installation...")
        print()

        # Run without capturing output so user sees progress
        self.runner.run(cmd, capture=False)

        print()
        self.logger.success("Installation complete!")
        self._print_post_install_instructions()

    def _print_post_install_instructions(self) -> None:
        """Print post-installation instructions."""
        print()
        self.logger.info("The system will reboot. After reboot:")
        print(f"    1. SSH to the new system: ssh coryg@{self.config.target}")
        print("    2. Verify sops secrets are decrypted")
        print("    3. Clone your dotfiles to /etc/nixos for auto-upgrades")
        print()

    def _cleanup(self) -> None:
        """Clean up temporary files and print final notes."""
        temp_dir = self.config.temp_dir

        if temp_dir and temp_dir.exists():
            self.logger.info(f"Temporary files preserved at: {temp_dir}")
            self.logger.info(
                "Contains SSH host keys - back these up or delete after verifying install"
            )


class InstallationError(Exception):
    """Exception raised for installation failures."""

    pass
