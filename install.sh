#!/bin/bash
# Idempotent installer for the Omarchy touchscreen-as-touchpad setup.
# Run from this directory: ./install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$HOME/.local/bin/touchpad-touch"
INPUT_LUA="$HOME/.config/hypr/input.lua"
AUTOSTART_LUA="$HOME/.config/hypr/autostart.lua"
DEVICE_NAME="goodix-capacitive-touchscreen-1"   # as shown by `hyprctl devices` (touch section)
STALE_NAMES="gxtp7385:00-27c6:0118\|goodix-capacitive-touchscreen"

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

if grep -q "name = \"$DEVICE_NAME\"" "$INPUT_LUA" 2>/dev/null; then
  log "input.lua already disables $DEVICE_NAME"
elif grep -q "$STALE_NAMES" "$INPUT_LUA" 2>/dev/null; then
  log "Replacing stale touchscreen device name in $INPUT_LUA"
  sed -i 's/name = "gxtp7385:00-27c6:0118"/name = "goodix-capacitive-touchscreen-1"/;
          s/name = "goodix-capacitive-touchscreen"/name = "goodix-capacitive-touchscreen-1"/' "$INPUT_LUA"
else
  log "Adding device disable to $INPUT_LUA"
  cat >> "$INPUT_LUA" <<EOF

-- Touchscreen acts as a relative touchpad via ~/.local/bin/touchpad-touch,
-- so disable Hyprland's absolute touch mapping for the panel.
hl.device({
  name = "$DEVICE_NAME",
  enabled = false,
})
EOF
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
