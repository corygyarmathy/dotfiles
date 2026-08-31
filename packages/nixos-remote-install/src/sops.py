"""SOPS and age key management utilities."""

from __future__ import annotations

import re
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from commands import CommandRunner
    from config import InstallConfig
    from logger import Logger


class SopsManager:
    """Manages SOPS configuration and age key handling."""

    # Pattern to match age public keys
    AGE_KEY_PATTERN = re.compile(r"^age1[a-z0-9]{58}$")

    # Pattern to find placeholder keys in .sops.yaml
    PLACEHOLDER_PATTERN = re.compile(
        r"- &(\w+)\s+age1PLACEHOLDER[A-Z_]*",
        re.MULTILINE,
    )

    def __init__(
        self,
        config: InstallConfig,
        runner: CommandRunner,
        logger: Logger,
    ) -> None:
        """
        Initialise the SOPS manager.

        Args:
            config: Installation configuration
            runner: Command runner instance
            logger: Logger instance
        """
        self.config = config
        self.runner = runner
        self.logger = logger

    def generate_ssh_host_key(self) -> Path:
        """
        Generate an ED25519 SSH host key pair.

        Returns:
            Path to the private key file

        Raises:
            FileExistsError: If key already exists (unless confirmed to overwrite)
        """
        key_path = self.config.ssh_private_key

        # Ensure temp directory exists
        key_path.parent.mkdir(parents=True, exist_ok=True)

        if key_path.exists():
            self.logger.warn(f"SSH host key already exists: {key_path}")
            if not self.config.auto_confirm:
                if not self.logger.confirm("Regenerate key?", default=False):
                    self.logger.info("Using existing key")
                    return key_path

            # Remove existing keys
            key_path.unlink()
            if self.config.ssh_public_key.exists():
                self.config.ssh_public_key.unlink()

        self.logger.step(f"Generating SSH host key for '{self.config.hostname}'")

        self.runner.run(
            [
                "ssh-keygen",
                "-t",
                "ed25519",
                "-f",
                str(key_path),
                "-N",
                "",  # Empty passphrase
                "-C",
                f"root@{self.config.hostname}",
            ],
        )

        self.logger.success(f"Generated: {key_path}")
        self.logger.success(f"Generated: {self.config.ssh_public_key}")

        return key_path

    def derive_age_key(self) -> str:
        """
        Derive an age public key from the SSH host key.

        Returns:
            The age public key string

        Raises:
            FileNotFoundError: If SSH public key doesn't exist
            ValueError: If derived key doesn't match expected format
        """
        if not self.config.ssh_public_key.exists():
            raise FileNotFoundError(
                f"SSH public key not found: {self.config.ssh_public_key}"
            )

        self.logger.step("Deriving age public key from SSH host key")

        # Read the SSH public key
        ssh_pub_key = self.config.ssh_public_key.read_text().strip()

        # Use ssh-to-age to convert
        result = self.runner.run(
            ["ssh-to-age"],
            input_text=ssh_pub_key,
        )

        age_key = result.stdout.strip()

        # Validate the key format
        if not self.AGE_KEY_PATTERN.match(age_key):
            raise ValueError(f"Invalid age key format: {age_key}")

        # Save the age key for reference
        self.config.age_public_key_file.write_text(age_key)

        self.logger.success(f"Age public key: {age_key}")

        return age_key

    def read_age_key(self) -> str | None:
        """Read the previously derived age key from file."""
        if self.config.age_public_key_file.exists():
            return self.config.age_public_key_file.read_text().strip()
        return None

    def update_sops_yaml(self, age_key: str) -> bool:
        """
        Update .sops.yaml with the new host's age key.

        Args:
            age_key: The age public key to add

        Returns:
            True if updated successfully, False if manual update needed
        """
        sops_path = self.config.sops_config

        if not sops_path.exists():
            self.logger.warn(f".sops.yaml not found at {sops_path}")
            self._print_manual_sops_instructions(age_key)
            return False

        self.logger.step("Checking .sops.yaml configuration")

        content = sops_path.read_text()

        # Check if key already present
        if age_key in content:
            self.logger.success("Age key already present in .sops.yaml")
            return True

        # Check for placeholder
        hostname = self.config.hostname
        placeholder_match = re.search(
            rf"- &{hostname}\s+age1PLACEHOLDER[A-Z_]*",
            content,
        )

        if placeholder_match:
            self.logger.info(f"Found placeholder for {hostname}, updating...")

            # Replace placeholder with actual key
            new_content = re.sub(
                rf"(- &{hostname}\s+)age1PLACEHOLDER[A-Z_]*",
                rf"\g<1>{age_key}",
                content,
            )

            if self.config.dry_run:
                self.logger.info("[DRY RUN] Would update .sops.yaml")
                return True

            sops_path.write_text(new_content)
            self.logger.success("Updated .sops.yaml with new key")
            return True

        # Check if hostname anchor exists with a different key
        if re.search(rf"- &{hostname}\s+age1", content):
            self.logger.warn(f"Host {hostname} already has a key in .sops.yaml")
            self.logger.warn("Please verify the existing key is correct")
            return True

        # No placeholder found, need manual update
        self.logger.warn(f"No placeholder found for {hostname}")
        self._print_manual_sops_instructions(age_key)
        return False

    def _print_manual_sops_instructions(self, age_key: str) -> None:
        """Print instructions for manual .sops.yaml update."""
        hostname = self.config.hostname

        print()
        self.logger.info("Please add the following to your .sops.yaml:")
        print()
        print("  keys:")
        print(f"    - &{hostname} {age_key}")
        print()
        print("  And add it to your creation_rules key_groups:")
        print(f"    - *{hostname}")
        print()

    def rekey_secrets(self) -> bool:
        """
        Re-encrypt all secrets files with the updated keys.

        Returns:
            True if successful
        """
        self.logger.step("Re-encrypting secrets with new host key")

        # Find all secrets files
        secrets_files: list[Path] = []

        for pattern in ["secrets.yaml", "secrets.yml"]:
            secrets_files.extend(self.config.flake_dir.rglob(pattern))

        # Filter out hidden directories and common non-secret files
        secrets_files = [
            f
            for f in secrets_files
            if not any(part.startswith(".") for part in f.parts[:-1])
            and "node_modules" not in f.parts
        ]

        if not secrets_files:
            self.logger.warn("No secrets.yaml files found")
            return True

        success = True

        for secret_file in secrets_files:
            self.logger.substep(
                f"Re-keying: {secret_file.relative_to(self.config.flake_dir)}"
            )

            if self.config.dry_run:
                continue

            try:
                self.runner.run(
                    ["sops", "updatekeys", "-y", str(secret_file)],
                )
            except Exception as exc:
                self.logger.error(f"Failed to re-key {secret_file}: {exc}")
                success = False

        if success:
            self.logger.success("Secrets re-encrypted")
            self._print_git_reminder()

        return success

    def _print_git_reminder(self) -> None:
        """Print reminder to commit changes."""
        print()
        self.logger.warn("Remember to commit and push the updated secrets:")
        print(f"    git add .sops.yaml secrets/")
        print(f"    git commit -m 'Add {self.config.hostname} host key'")
        print("    git push")
        print()
