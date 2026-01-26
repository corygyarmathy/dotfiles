# Disko configuration for homelab02
# HP Elitedesk 800 G6 SFF - NAS + services
#
# Disk Layout:
#   - NVMe: OS (boot + root)
#   - 2x 4TB HDD: Data storage (individual ext4, pooled via MergerFS)
#
# Usage with nixos-anywhere:
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#homelab02 \
#     --disk main /dev/nvme0n1 \
#     --disk data1 /dev/disk/by-id/ata-ST4000VN006-XXXXXXXX \
#     --disk data2 /dev/disk/by-id/ata-ST4000VN006-YYYYYYYY \
#     root@<IP>
#
# NOTE: Find disk serial numbers with: ls -la /dev/disk/by-id/ | grep ST4000VN006
# WARNING: if updating after system is built, manual partitioning is needed first!
# If not performed the system will crash and fail to boot. Will need to be booted
# to the previous generation.
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

      # ========================================================================
      # Data Disk 1 (4TB HDD)
      # ========================================================================
      # Get actual disk ID from:
      # ls -la /dev/disk/by-id/ | grep ST4000VN006
      data1 = {
        type = "disk";
        # Use disk-by-id for reliable identification across reboots
        device = "/dev/disk/by-id/ata-ST4000VN006-3CW104_WW68ES3V";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/data/disk1";
                mountOptions = [
                  "defaults"
                  "noatime"
                  # Optimize for large sequential writes (media files)
                  "data=writeback"
                  "barrier=0"
                  "nobh"
                ];
              };
            };
          };
        };
      };

      # ========================================================================
      # Data Disk 2 (4TB HDD)
      # ========================================================================
      data2 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-ST4000VN006-3CW104_WW68ETEH";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/data/disk2";
                mountOptions = [
                  "defaults"
                  "noatime"
                  "data=writeback"
                  "barrier=0"
                  "nobh"
                ];
              };
            };
          };
        };
      };
    };
  };
}
