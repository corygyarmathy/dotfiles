# modules/nixos/audit.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.audit;
in
{
  options.cg.audit = {
    enable = lib.mkEnableOption "System audit logging";

    logExecutions = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Log all program executions (verbose, useful for forensics)";
    };
  };

  config = lib.mkIf cfg.enable {
    security.auditd.enable = true;
    security.audit = {
      enable = true;
      rules = [
        # Authentication and identity changes
        "-w /etc/passwd -p wa -k identity"
        "-w /etc/group -p wa -k identity"
        "-w /etc/shadow -p wa -k identity"
        "-w /etc/gshadow -p wa -k identity"

        # Privilege escalation configs
        "-w /etc/sudoers -p wa -k sudoers"
        "-w /etc/sudoers.d -p wa -k sudoers"

        # SSH configuration
        "-w /etc/ssh/sshd_config -p wa -k sshd"
        "-w /etc/ssh/ssh_config -p wa -k ssh"

        # Cron and scheduled tasks
        "-w /etc/crontab -p wa -k cron"
        "-w /etc/cron.d -p wa -k cron"
        "-w /var/spool/cron -p wa -k cron"

        # Systemd services (detect new services being added)
        "-w /etc/systemd/system -p wa -k systemd"
        "-w /etc/systemd/user -p wa -k systemd"

        # Network configuration
        "-w /etc/hosts -p wa -k network"
        "-w /etc/resolv.conf -p wa -k network"

        # NixOS specific - configuration changes
        "-w /etc/nixos -p wa -k nixos"

        # Kernel module loading (execution of module tools)
        "-w /usr/bin/kmod -p x -k modules"

        # Monitor privilege escalation attempts
        "-a always,exit -F arch=b64 -S setuid -S setgid -S setreuid -S setregid -k privilege_escalation"

        # Monitor unsuccessful access attempts (permission denied)
        "-a always,exit -F arch=b64 -S open -S openat -F exit=-EACCES -k access_denied"
        "-a always,exit -F arch=b64 -S open -S openat -F exit=-EPERM -k access_denied"
      ]
      # Optionally log all executions (verbose)
      ++ lib.optionals cfg.logExecutions [
        "-a always,exit -F arch=b64 -S execve -k exec"
      ];
    };

    environment.systemPackages = [ pkgs.audit ];
  };
}
