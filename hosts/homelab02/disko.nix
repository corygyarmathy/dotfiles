# Disko configuration for homelab02
# HP Elitedesk 800 G6 SFF - NAS + services
#
# This defines the disk layout declaratively.
# The actual device path will be determined during installation.
#
# Usage with nixos-anywhere:
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#homelab02 \
#     --disk main /dev/sdX \
#     root@<IP>
#
# The `--disk main /dev/sdX` maps the "main" disk defined here to the actual device.
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        # Device is set via --disk flag during installation
        # e.g., --disk main /dev/nvme0n1 or --disk main /dev/sda
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            # EFI System Partition
            ESP = {
              priority = 1;
              name = "ESP";
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                  "umask=0077"
                ];
              };
            };

            # Root partition - ext4 for simplicity and reliability
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                mountOptions = [
                  "defaults"
                  "noatime" # Reduces disk writes
                ];
              };
            };
          };
        };
      };
    };
  };
}
