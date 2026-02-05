# Disko configuration for homelab02
# HP Elitedesk 800 G6 SFF - NAS + services
#
# This manages ALL disks declaratively:
#   - NVMe: OS (boot + root)
#   - 2x 4TB HDD: Data storage (individual ext4, pooled via ZFS)
#
# Fresh install with nixos-anywhere:
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#homelab02 \
#     root@10.20.2.130
#
# NOTE: Find disk serial numbers with: ls -la /dev/disk/by-id/ | grep ST4000VN006
# Disko will automatically find and partition the disks based on the
# device paths specified below.
{
  disko.devices = {
    disk = {
      # ========================================================================
      # OS Disk (NVMe)
      # ========================================================================
      main = {
        type = "disk";
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
