# Wake-from-suspend device configuration
# Enables keyboard, mouse, and dock to wake the system from suspend
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.wake-devices;
in
{
  options.cg.wake-devices = {
    enable = lib.mkEnableOption "Configure devices to wake system from suspend";

    keyboard = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable keyboard wake";
    };

    mouse = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable mouse wake";
    };

    thunderbolt = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Thunderbolt dock wake";
    };

    bluetooth = lib.mkOption {
      type = lib.types.bool;
      default = false;  # Changed to false - Bluetooth often causes spurious wakes
      description = "Enable Bluetooth device wake (Warning: may cause immediate wake from suspend)";
    };

    disableBluetoothWake = lib.mkOption {
      type = lib.types.bool;
      default = true;  # Explicitly disable Bluetooth wake to prevent spurious wakes
      description = "Explicitly disable Bluetooth wake to prevent spurious wakeups";
    };

    forceS3Sleep = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Force S3 (deep) sleep instead of s2idle (modern standby).
        S3 has better USB wake support but may have compatibility issues.
        Set to true if USB wake doesn't work with s2idle.
        
        Note: If using Nvidia, you should disable NVreg_EnableS0ixPowerManagement
        in your nvidia.nix module for S3 to work properly with USB wake.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Warnings about Nvidia conflicts
    warnings = 
      lib.optional 
        (cfg.forceS3Sleep && config.cg.nvidia.enable)
        ''
          wake-devices: You've enabled S3 sleep with Nvidia GPU.
          
          USB wake is working, but Nvidia may prevent proper suspend.
          
          If you see "NVRM: PreserveVideoMemoryAllocations" errors in dmesg,
          you need to enable Nvidia power management in nvidia.nix:
          
            hardware.nvidia.powerManagement.enable = true;
          
          You may also want to remove the S0ix parameter:
            # "nvidia.NVreg_EnableS0ixPowerManagement=1"
        ''
      ++ lib.optional
        (!cfg.forceS3Sleep && config.cg.nvidia.enable)
        ''
          wake-devices: USB wake with s2idle may not work reliably with Nvidia.
          
          If USB wake doesn't work, try:
            cg.wake-devices.forceS3Sleep = true;
        '';

    # Force S3 sleep if requested
    boot.kernelParams = lib.optionals cfg.forceS3Sleep [
      "mem_sleep_default=deep"
    ];

    # Create a script to enable wake for USB devices
    systemd.services.enable-usb-wake = {
      description = "Enable USB device wake from suspend";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Function to enable wake for a device and its parents
        enable_wake_recursive() {
          local device_path="$1"
          local device_name="$2"
          
          # Enable wake for this device
          if [[ -e "$device_path/power/wakeup" ]]; then
            echo "Enabling wake for $device_name at $device_path"
            echo enabled > "$device_path/power/wakeup"
          fi
          
          # Also enable wake for parent USB device (go up the hierarchy)
          local parent="$device_path"
          while [[ "$parent" != "/sys/bus/usb/devices" ]] && [[ "$parent" != "/sys" ]]; do
            parent=$(dirname "$parent")
            if [[ -e "$parent/power/wakeup" ]]; then
              local parent_name=$(basename "$parent")
              echo "Enabling wake for parent $parent_name"
              echo enabled > "$parent/power/wakeup"
            fi
          done
        }

        ${lib.optionalString cfg.keyboard ''
          # Find keyboard by looking for known vendors or HID keyboard devices
          echo "=== Looking for keyboards ==="
          
          # Method 1: Find by product description
          for device in /sys/bus/usb/devices/*/product; do
            product=$(cat "$device" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            if [[ "$product" =~ keyboard ]] || [[ "$product" =~ "moonlander" ]]; then
              device_path=$(dirname "$device")
              echo "Found keyboard: $product"
              enable_wake_recursive "$device_path" "Keyboard ($product)"
            fi
          done
          
          # Method 2: Find by manufacturer
          for device in /sys/bus/usb/devices/*/manufacturer; do
            manufacturer=$(cat "$device" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            if [[ "$manufacturer" =~ "zsa" ]]; then
              device_path=$(dirname "$device")
              product=$(cat "$device_path/product" 2>/dev/null || echo "Unknown")
              echo "Found ZSA device: $product"
              enable_wake_recursive "$device_path" "ZSA Keyboard ($product)"
            fi
          done
          
          # Method 3: Enable by specific vendor:product IDs we saw in lsusb
          # ZSA Moonlander: 3297:1969
          for device in /sys/bus/usb/devices/*; do
            if [[ -e "$device/idVendor" ]] && [[ -e "$device/idProduct" ]]; then
              vendor=$(cat "$device/idVendor" 2>/dev/null)
              product=$(cat "$device/idProduct" 2>/dev/null)
              
              # ZSA Moonlander
              if [[ "$vendor" == "3297" ]] && [[ "$product" == "1969" ]]; then
                echo "Found Moonlander keyboard by VID:PID"
                enable_wake_recursive "$device" "Moonlander Keyboard"
              fi
            fi
          done
          
          # Method 4: Find ALL HID devices and enable them (keyboards/mice often share this)
          for device in /sys/bus/usb/devices/*/bInterfaceClass; do
            if [[ "$(cat "$device" 2>/dev/null)" == "03" ]]; then
              device_path=$(dirname "$device")
              # This is the interface, go up to the actual device
              usb_device=$(dirname "$device_path")
              if [[ -e "$usb_device/product" ]]; then
                product=$(cat "$usb_device/product" 2>/dev/null || echo "HID Device")
                enable_wake_recursive "$usb_device" "HID Device ($product)"
              fi
            fi
          done
        ''}

        ${lib.optionalString cfg.mouse ''
          echo "=== Looking for mice ==="
          
          # Method 1: Find by product description
          for device in /sys/bus/usb/devices/*/product; do
            product=$(cat "$device" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            if [[ "$product" =~ mouse ]] || [[ "$product" =~ "unifying" ]]; then
              device_path=$(dirname "$device")
              echo "Found mouse/receiver: $product"
              enable_wake_recursive "$device_path" "Mouse ($product)"
            fi
          done
          
          # Method 2: Logitech Unifying Receiver - 046d:c52b
          for device in /sys/bus/usb/devices/*; do
            if [[ -e "$device/idVendor" ]] && [[ -e "$device/idProduct" ]]; then
              vendor=$(cat "$device/idVendor" 2>/dev/null)
              product=$(cat "$device/idProduct" 2>/dev/null)
              
              # Logitech Unifying Receiver
              if [[ "$vendor" == "046d" ]] && [[ "$product" == "c52b" ]]; then
                echo "Found Logitech Unifying Receiver by VID:PID"
                enable_wake_recursive "$device" "Logitech Unifying Receiver"
              fi
            fi
          done
        ''}

        ${lib.optionalString cfg.thunderbolt ''
          echo "=== Enabling Thunderbolt wake ==="
          # Enable wake for Thunderbolt controller and dock
          for device in /sys/bus/thunderbolt/devices/*; do
            if [[ -e "$device/power/wakeup" ]]; then
              device_name=$(basename "$device")
              echo "Enabling wake for Thunderbolt: $device_name"
              echo enabled > "$device/power/wakeup"
            fi
          done

          # Enable wake for USB host controllers (especially Thunderbolt ones)
          for device in /sys/bus/pci/devices/*/; do
            if [[ -e "$device/class" ]]; then
              class=$(cat "$device/class" 2>/dev/null)
              # USB controller class codes: 0x0c03xx
              if [[ "$class" =~ ^0x0c03 ]]; then
                if [[ -e "$device/power/wakeup" ]]; then
                  device_name=$(basename "$device")
                  echo "Enabling wake for USB Controller: $device_name"
                  echo enabled > "$device/power/wakeup"
                fi
              fi
              # Thunderbolt controller: 0x0c0a00
              if [[ "$class" == "0x0c0a00" ]]; then
                if [[ -e "$device/power/wakeup" ]]; then
                  device_name=$(basename "$device")
                  echo "Enabling wake for Thunderbolt Controller: $device_name"
                  echo enabled > "$device/power/wakeup"
                fi
              fi
            fi
          done
        ''}

        ${lib.optionalString cfg.bluetooth ''
          echo "=== Enabling Bluetooth wake ==="
          # Enable wake for Bluetooth USB adapter
          for device in /sys/bus/usb/devices/*/product; do
            product=$(cat "$device" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            if [[ "$product" =~ bluetooth ]]; then
              device_path=$(dirname "$device")
              echo "Found Bluetooth adapter: $product"
              enable_wake_recursive "$device_path" "Bluetooth ($product)"
            fi
          done
        ''}

        ${lib.optionalString cfg.disableBluetoothWake ''
          echo "=== Disabling Bluetooth wake (to prevent spurious wakes) ==="
          # Disable wake for Bluetooth controllers
          for device in /sys/bus/usb/devices/*/product; do
            product=$(cat "$device" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            if [[ "$product" =~ bluetooth ]]; then
              device_path=$(dirname "$device")
              if [[ -e "$device_path/power/wakeup" ]]; then
                echo "Disabling wake for Bluetooth: $product"
                echo disabled > "$device_path/power/wakeup"
              fi
            fi
          done
          
          # Also disable for any device with "8087:0026" (Intel Bluetooth from your lsusb)
          for device in /sys/bus/usb/devices/*; do
            if [[ -e "$device/idVendor" ]] && [[ -e "$device/idProduct" ]]; then
              vendor=$(cat "$device/idVendor" 2>/dev/null)
              product=$(cat "$device/idProduct" 2>/dev/null)
              
              # Intel AX201 Bluetooth
              if [[ "$vendor" == "8087" ]] && [[ "$product" == "0026" ]]; then
                if [[ -e "$device/power/wakeup" ]]; then
                  echo "Disabling wake for Intel Bluetooth by VID:PID"
                  echo disabled > "$device/power/wakeup"
                fi
              fi
            fi
          done
        ''}

        # Log all USB devices with wake enabled
        echo ""
        echo "=== All USB devices with wake enabled ==="
        for device in /sys/bus/usb/devices/*/power/wakeup; do
          if [[ "$(cat "$device" 2>/dev/null)" == "enabled" ]]; then
            device_path=$(dirname "$(dirname "$device")")
            device_name=$(basename "$device_path")
            product=$(cat "$device_path/product" 2>/dev/null || echo "Unknown")
            echo "  $device_name: $product"
          fi
        done
      '';
    };

    # udev rules to enable wake when devices are plugged in
    services.udev.extraRules = ''
      # Enable wake for any USB device with specific vendor IDs
      ${lib.optionalString cfg.keyboard ''
        # ZSA Moonlander keyboard - 3297:1969
        ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="3297", ATTR{idProduct}=="1969", RUN+="${pkgs.bash}/bin/bash -c 'echo enabled > %S%p/power/wakeup'"
      ''}

      ${lib.optionalString cfg.mouse ''
        # Logitech Unifying Receiver - 046d:c52b
        ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{idProduct}=="c52b", RUN+="${pkgs.bash}/bin/bash -c 'echo enabled > %S%p/power/wakeup'"
      ''}

      # Enable wake for all HID devices (keyboards, mice, etc.)
      ${lib.optionalString (cfg.keyboard || cfg.mouse) ''
        ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", RUN+="${pkgs.bash}/bin/bash -c 'echo enabled > %S%p/../power/wakeup'"
      ''}

      # Enable wake for USB hubs (important for docked devices)
      ${lib.optionalString (cfg.keyboard || cfg.mouse) ''
        ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="09", RUN+="${pkgs.bash}/bin/bash -c 'echo enabled > %S%p/power/wakeup'"
      ''}

      # Enable wake for Thunderbolt devices
      ${lib.optionalString cfg.thunderbolt ''
        ACTION=="add", SUBSYSTEM=="thunderbolt", RUN+="${pkgs.bash}/bin/bash -c 'if [[ -e %S%p/power/wakeup ]]; then echo enabled > %S%p/power/wakeup; fi'"
      ''}
    '';

    # Install debugging tools
    environment.systemPackages = with pkgs; [
      usbutils  # lsusb
      pciutils  # lspci
    ];
  };
}
