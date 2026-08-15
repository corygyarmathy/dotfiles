# Waybar status for the NixOS upgrade module.
#
# Emits {"text","tooltip","class"} for waybar's custom module.
#
# There is no state file. Every state this reports is already tracked
# somewhere authoritative:
#
#   applying / building   systemd ActiveState
#   error                 systemd ActiveState = failed
#   update pending        the built system differs from the running one
#   reboot required       its kernel/initrd/modules differ from the booted ones
#   firmware pending      fwupdmgr get-updates (~70ms, local daemon, no network)
#
# The previous implementation kept a JSON state machine in parallel with all of
# that, which could disagree with reality and then had to be reconciled. This
# cannot: it reads the sources directly every time.
#
# Note this runs under `set -euo pipefail` (writeShellApplication), so every
# test that is allowed to fail is written as an `if`, never as `a && b` at
# statement level - a failing `&&` list would abort the script and waybar would
# render an empty module.

NEXT_LINK="/var/lib/nixos-upgrade/next"
CURRENT="/run/current-system"
BOOTED="/run/booted-system"

emit() {
  # jq handles escaping, so a tooltip containing a quote or newline cannot
  # produce invalid JSON and blank the module.
  jq -cn --arg text "$1" --arg tooltip "$2" --arg class "$3" \
    '{text: $text, tooltip: $tooltip, class: $class}'
  exit 0
}

state_of() {
  systemctl show -P ActiveState "$1" 2>/dev/null || echo unknown
}

kernel_of() {
  # Three symlinks; differing in any of them means a reboot is required. Brace
  # expansion gives one readlink call.
  readlink "$1"/{initrd,kernel,kernel-modules} 2>/dev/null || true
}

# --- in-flight states take precedence over anything derived ------------------

if [ "$(state_of nixos-upgrade-apply.service)" = "active" ]; then
  emit "⟳" "Applying updates…" "applying"
fi

if [ "$(state_of nixos-upgrade-build.service)" = "active" ]; then
  emit "󰔟" "Building updates in the background…" "building"
fi

if [ "$(state_of nixos-upgrade-apply.service)" = "failed" ]; then
  emit "⚠" "Update failed to apply. Middle-click for logs." "error"
fi

if [ "$(state_of nixos-upgrade-build.service)" = "failed" ]; then
  emit "⚠" "Update failed to build. Middle-click for logs." "error"
fi

# --- what is pending --------------------------------------------------------

booted_kernel="$(kernel_of "$BOOTED")"
current_kernel="$(kernel_of "$CURRENT")"

nix_pending=false
reboot_required=false

if [ -L "$NEXT_LINK" ]; then
  next="$(readlink -f "$NEXT_LINK" 2>/dev/null || true)"
  current="$(readlink -f "$CURRENT" 2>/dev/null || true)"

  if [ -n "$next" ] && [ "$next" != "$current" ]; then
    nix_pending=true

    # The same comparison nixos-upgrade makes: only a changed kernel, initrd or
    # module set actually requires a reboot. A pure userspace change is applied
    # by switching, and claiming otherwise trains you to ignore the indicator.
    next_kernel="$(kernel_of "$next")"
    if [ -n "$booted_kernel" ] && [ "$booted_kernel" != "$next_kernel" ]; then
      reboot_required=true
    fi
  fi
fi

# Nothing new to apply, but the running system's kernel is not the booted one:
# an update was applied earlier and the reboot has not happened yet.
if [ "$nix_pending" = false ] && [ -n "$booted_kernel" ] && [ "$booted_kernel" != "$current_kernel" ]; then
  emit "🔄" "Reboot required to finish applying an update" "reboot-needed"
fi

fw_count=0
if command -v fwupdmgr >/dev/null 2>&1; then
  fw_count="$(fwupdmgr get-updates --json 2>/dev/null | jq '.Devices | length' 2>/dev/null || echo 0)"
fi

# --- report -----------------------------------------------------------------

if [ "$nix_pending" = true ] || [ "$fw_count" -gt 0 ]; then
  parts=""
  if [ "$nix_pending" = true ]; then
    parts="system update"
  fi

  if [ "$fw_count" -gt 0 ]; then
    if [ "$fw_count" -eq 1 ]; then
      fw_text="1 firmware update"
    else
      fw_text="$fw_count firmware updates"
    fi
    if [ -n "$parts" ]; then
      parts="$parts, $fw_text"
    else
      parts="$fw_text"
    fi
  fi

  if [ "$reboot_required" = true ]; then
    emit "🔄" "Ready to apply: $parts (reboot required). Click to apply." "reboot-needed"
  fi

  emit "📦" "Ready to apply: $parts. Click to apply." "ready"
fi

emit "✓" "Up to date" "up-to-date"
