# Omarchy Touchscreen-as-Touchpad

Turns the built-in touchscreen of this device into a **relative touchpad**
instead of an absolute touch screen, under Omarchy (Arch + Hyprland with the
Lua config system).

```
one-finger drag   -> relative cursor motion (with acceleration)
one-finger tap    -> left click
two-finger tap    -> right click
two-finger drag   -> vertical wheel scrolling
```

The stylus digitizer is intentionally left untouched and keeps working as an
absolute pen.

## Components

| Piece | Location | Purpose |
|---|---|---|
| Daemon | `~/.local/bin/touchpad-touch` | Reads raw evdev events from the panel, drives cursor/clicks/scroll. Snapshot in this repo: [`touchpad-touch`](touchpad-touch) |
| Device disable | `~/.config/hypr/input.lua` | `hl.device({ name = "gxtp7385:00-27c6:0118", enabled = false })` — stops Hyprland's absolute touch handling |
| Autostart | `~/.config/hypr/autostart.lua` | `o.exec_on_start(os.getenv("HOME") .. "/.local/bin/touchpad-touch")` |
| Synthetic input | `ydotool` package + `ydotool.service` (systemd **user** unit shipped by the package) | Clicks and wheel events (`ydotoold` talks to `/dev/uinput`) |
| Python evdev | `python-evdev` package | Raw event reading |

Package versions this was built against: `ydotool 1.0.4-2`, `python-evdev 1.9.3-1`.
User must be in the `input` group (already true on Omarchy).

## Hardware facts (this machine)

* Touch controller: Goodix `GXTP7385:00 27C6:0118`, i2c device, exposes **four**
  evdev nodes. Only the main node carries finger data; the others never emit
  during finger touches:

  | Node | Name suffix | Notes |
  |---|---|---|
  | `event19` (numbering can change!) | *(none)* | The multitouch finger node — the only one the daemon reads |
  | `event20` | ` Stylus` | Pen input; left enabled so the pen still works |
  | `event21` | ` UNKNOWN` | Silent for fingers |
  | `event22` | ` Keyboard` | Silent for fingers |

* Main node protocol quirk: it does **not** use `ABS_MT_SLOT`. It emits
  `ABS_MT_TRACKING_ID` (sequential ids, `-1` on lift) +
  `ABS_MT_POSITION_X/Y`, plus legacy duplicate `ABS_X/ABS_Y` and `BTN_TOUCH`,
  all strictly one contact at a time.
* Digitizer range: `3600 x 5760` (portrait aspect).
* Panel: eDP-1, mode `1200x1920@60`, `scale = 2`, `transform = 1`
  (see `~/.config/hypr/monitors.lua`) → logical footprint `600x960`.

### Axis mapping (why `TOUCH_TRANSFORM = 4`)

Empirically calibrated on this unit:

* Finger moving physically **right** produces digitizer **−Y** motion.
* Finger moving physically **up** produces digitizer **−X** motion.

So screen deltas are `(−dy, +dx)` — transform code `4` in the script:

| code | delta map |
|---|---|
| 0 | `(x, y)` |
| 1 | `(−y, −x)` |
| 2 | `(−x, −y)` |
| 3 | `(y, x)` |
| **4** | **`(−y, x)` ← this panel** |
| 5 | `(y, −x)` |

If monitor geometry ever changes (different rotation in `monitors.lua`),
re-check directions and adjust `TOUCH_TRANSFORM` in the script (or override at
runtime with the `TOUCH_TRANSFORM` env var).

Scale comes out uniform: `600 px / 3600 units × GAIN(1.6) ≈ 0.267 px/unit`.

## Hyprland build quirks (important!)

This Omarchy ships a Hyprland where config/dispatch requests are evaluated as
**Lua**. Several classic commands do not exist or behave differently:

1. **No `movecursor` dispatcher.** Relative cursor motion is done atomically
   over the IPC socket with:
   ```lua
   local p = hl.get_cursor_pos()
   hl.dispatch(hl.dsp.cursor.move({ x = p.x + DX, y = p.y + DY }))
   ```
   sent as `eval <code>` over `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`.
   (`hl.dsp.cursor.move` alone is absolute.)
2. **`hyprctl keyword` is rejected** ("can't work with non-legacy parsers") —
   runtime changes go through `hyprctl eval '...'` as well.
3. **Nested device tables inside `hl.config()` silently fail to serialize.**
   This caused a long debugging saga: `hl.config({ input = { device = { {...} } } })`
   reloads without errors but does nothing. The working API is a top-level
   ```lua
   hl.device({ name = "<device name as shown by hyprctl devices>", enabled = false })
   ```
4. `hyprctl getoption device:<name>:enabled` returns "no such option" — device
   configs are not introspectable that way, so you cannot verify the disable
   via getoption.
5. **Verification caveat:** a virtual uinput device with the same name is *not*
   proof that the disable rule works — libinput may ignore the synthetic device
   for other reasons (missing `BTN_TOOL_FINGER`, etc.). The reliable test is
   touching the real panel: if content scrolls or the cursor vanishes while
   touching, Hyprland is still processing the device.

## Rebuild from scratch

Quick path: run [`install.sh`](install.sh) (idempotent; uses sudo/pkexec only
for pacman).

Manual steps, for reference:

1. Packages:
   ```bash
   sudo pacman -S --needed --noconfirm ydotool python-evdev
   systemctl --user enable --now ydotool.service
   ```
2. Install the daemon and make it executable:
   ```bash
   cp touchpad-touch ~/.local/bin/touchpad-touch && chmod +x ~/.local/bin/touchpad-touch
   ```
3. In `~/.config/hypr/input.lua` add:
   ```lua
   hl.device({
     name = "gxtp7385:00-27c6:0118",
     enabled = false,
   })
   ```
   (Use the lowercased name exactly as `hyprctl devices` shows it.)
4. In `~/.config/hypr/autostart.lua` add:
   ```lua
   o.exec_on_start(os.getenv("HOME") .. "/.local/bin/touchpad-touch")
   ```
5. `hyprctl reload && hyprctl configerrors` — must be clean.
6. Start the daemon now (autostart only covers future sessions):
   ```bash
   setsid nohup ~/.local/bin/touchpad-touch >/dev/null 2>&1 &
   ```

## Tunables

All at the top of the script:

| Constant | Default | Meaning |
|---|---|---|
| `GAIN` | 1.6 | Base px-per-digitizer-unit multiplier |
| `ACCEL` / `ACCEL_RAMP` | 1.25 / 70 | Speed-dependent gain boost |
| `TAP_MS` | 200 | Max contact duration for tap-to-click |
| `TAP_SLOP` / `RIGHT_TAP_SLOP` | 16 / 26 px | Max travel during taps |
| `CLICK_GAP_MS` | 40 | Debounce between synthesized clicks |
| `SCROLL_DIV` | 14 | Finger px of travel per wheel notch |
| `NATURAL_SCROLL` | False | Scroll direction |
| `TOUCH_TRANSFORM` | 4 | Delta rotation map (see table above); `None` = derive from monitor transform |

Environment variables: `TOUCH_DEBUG=1` (log moves/clicks/wheel to stdout),
`TOUCH_DEVICE_PATH` or argv[1] (pin a specific `/dev/input/eventX` — used by
tests), `TOUCH_TRANSFORM` (override rotation).

## Operation & troubleshooting

* Single-instance guard: `flock` on `$XDG_RUNTIME_DIR/touchpad-touch.lock`;
  a second instance exits immediately (safe against double autostart).
* If the evdev node disappears (i2c reset), the daemon rescans every 3 s.
* Check it is running: `ps -eo pid,args | grep '[t]ouchpad-touch'`
* Restart it safely — **anchor the pattern**, an unanchored `pkill -f` will
  match (and kill) your own shell wrapper:
  ```bash
  kill $(pgrep -f '^python3 /home/ishcabittle/.local/bin/touchpad-touch$')
  setsid nohup ~/.local/bin/touchpad-touch >/dev/null 2>&1 &
  ```
* Symptom → cause cheat sheet:
  * Dragging scrolls window content / cursor vanishes while touching →
    Hyprland is processing the panel again (the `hl.device` disable is missing
    or was reverted). See quirk #3/#5 above.
  * Cursor moves but wrong direction → `TOUCH_TRANSFORM` no longer matches the
    monitor layout.
  * Taps don't click → is `ydotoold` alive? `systemctl --user status ydotool`.
* Debug run (foreground, verbose):
  ```bash
  TOUCH_DEBUG=1 python3 ~/.local/bin/touchpad-touch
  ```

## Uninstall

1. Remove the `hl.device` block from `input.lua` and the `exec_on_start` line
   from `autostart.lua`; `hyprctl reload`.
2. Kill the daemon (see anchored pattern above).
3. Optionally: `rm ~/.local/bin/touchpad-touch`,
   `systemctl --user disable --now ydotool.service`,
   `sudo pacman -Rns ydotool python-evdev`.
