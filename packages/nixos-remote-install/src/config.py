"""Configuration dataclass for NixOS remote installation."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class InstallConfig:
    """Configuration for a NixOS remote installation."""

    # Required parameters
    hostname: str
    target: str

    # SSH settings
    ssh_user: str = "nixos"
    ssh_port: int = 22

    # Disk configuration
    disk: str | None = None

    # Paths
    flake_dir: Path = field(default_factory=Path.cwd)
    temp_dir: Path | None = None

    # Behaviour flags
    skip_rekey: bool = False
    skip_sops: bool = False
    dry_run: bool = False
    auto_confirm: bool = False

    def __post_init__(self) -> None:
        """Validate and set derived paths."""
        # Ensure flake_dir is a Path
        if isinstance(self.flake_dir, str):
            self.flake_dir = Path(self.flake_dir)

        # Set default temp_dir if not provided
        if self.temp_dir is None:
            self.temp_dir = self.flake_dir / ".install-temp"
        elif isinstance(self.temp_dir, str):
            self.temp_dir = Path(self.temp_dir)

    @property
    def host_dir(self) -> Path:
        """Path to the host's configuration directory."""
        return self.flake_dir / "hosts" / self.hostname

    @property
    def disko_config(self) -> Path:
        """Path to the host's disko configuration."""
        return self.host_dir / "disko.nix"

    @property
    def hardware_config(self) -> Path:
        """Path to the host's hardware configuration."""
        return self.host_dir / "hardware.nix"

    @property
    def sops_config(self) -> Path:
        """Path to the .sops.yaml configuration file."""
        return self.flake_dir / ".sops.yaml"

    @property
    def ssh_private_key(self) -> Path:
        """Path to the pre-generated SSH private key."""
        assert self.temp_dir is not None
        return self.temp_dir / f"{self.hostname}_ssh_host_ed25519_key"

    @property
    def ssh_public_key(self) -> Path:
        """Path to the pre-generated SSH public key."""
        assert self.temp_dir is not None
        return self.temp_dir / f"{self.hostname}_ssh_host_ed25519_key.pub"

    @property
    def age_public_key_file(self) -> Path:
        """Path to store the derived age public key."""
        assert self.temp_dir is not None
        return self.temp_dir / f"{self.hostname}_age_public_key"

    @property
    def extra_files_dir(self) -> Path:
        """Path to the extra-files directory for nixos-anywhere."""
        assert self.temp_dir is not None
        return self.temp_dir / "extra-files"

    @property
    def ssh_target(self) -> str:
        """SSH connection string (user@host)."""
        return f"{self.ssh_user}@{self.target}"

    def ssh_options(self) -> list[str]:
        """Common SSH options as a list."""
        options = [
            "-o",
            "ConnectTimeout=10",
            "-o",
            "StrictHostKeyChecking=accept-new",
        ]
        if self.ssh_port != 22:
            options.extend(["-p", str(self.ssh_port)])
        return options
