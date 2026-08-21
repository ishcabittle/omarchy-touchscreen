#!/bin/bash
# Idempotent installer for the Omarchy touchscreen-as-touchpad setup.
# Run from this directory: ./install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$HOME/.local/bin/touchpad-touch"
INPUT_LUA="$HOME/.config/hypr/input.lua"
AUTOSTART_LUA="$HOME/.config/hypr/autostart.lua"
DEVICE_NAME="gxtp7385:00-27c6:0118"   # as shown by `hyprctl devices`

log() { printf '\033[32m==>\033[0m %s\n' "$*"; }

SUDO=""
if (( EUID != 0 )); then
  SUDO="sudo"
  command -v pkexec >/dev/null && ! sudo -n true 2>/dev/null && SUDO="pkexec"
fi

log "Installing packages (ydotool, python-evdev)"
$SUDO pacman -S --needed --noconfirm ydotool python-evdev

log "Enabling ydotoold user service"
systemctl --user enable --now ydotool.service

log "Installing daemon to $DAEMON"
install -Dm755 "$REPO_DIR/touchpad-touch" "$DAEMON"

if ! grep -q "hl.device" "$INPUT_LUA" 2>/dev/null; then
  log "Adding device disable to $INPUT_LUA"
  cat >> "$INPUT_LUA" <<EOF

-- Touchscreen acts as a relative touchpad via ~/.local/bin/touchpad-touch,
-- so disable Hyprland's absolute touch mapping for the panel.
hl.device({
  name = "$DEVICE_NAME",
  enabled = false,
})
EOF
else
  log "input.lua already has an hl.device block, skipping"
fi

if ! grep -q "touchpad-touch" "$AUTOSTART_LUA" 2>/dev/null; then
  log "Adding autostart entry to $AUTOSTART_LUA"
  cat >> "$AUTOSTART_LUA" <<EOF

-- Touchscreen-as-touchpad daemon (relative cursor, tap-to-click, two-finger scroll)
o.exec_on_start(os.getenv("HOME") .. "/.local/bin/touchpad-touch")
EOF
else
  log "autostart.lua already references touchpad-touch, skipping"
fi

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  log "Reloading Hyprland config"
  hyprctl reload
  hyprctl configerrors
fi

if ! pgrep -f '^python3 '"$DAEMON"'$' >/dev/null; then
  log "Starting daemon"
  setsid nohup "$DAEMON" >/dev/null 2>&1 < /dev/null &
  sleep 2
fi

pgrep -af '^python3 '"$DAEMON"'$' && log "Done - touch the panel to test."
