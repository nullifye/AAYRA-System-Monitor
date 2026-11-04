# AAYRA

A small menu bar system monitor for macOS (Swift + SwiftUI, Apple Silicon, macOS 15+).

- **Menu bar:** a turbine that spins slowly when the CPU is idle and faster as load rises, with motion blur above 80 %. Hover for the exact %, right-click for a quick menu. With *Reduce Motion* on, it stops spinning and shows the % as text instead.
- **Panel (click):** CPU (history, user/system, per-core, load average), memory (used, pressure, swap), disk free space, battery (charge, time remaining, health, cycles, temperature, capacity), network (Wi-Fi/Ethernet, live ↓/↑ speed, local and public IP, click to copy). Launch at Login toggle.

## Build & run
```bash
./build-app.sh --open      # builds AAYRA.app here and launches it
```
Move `AAYRA.app` to `/Applications` before enabling "Launch at Login".

The app icon is drawn in code; to change it, edit `scripts/make-icon.swift` and run `swift scripts/make-icon.swift`.

## Debug helpers
```bash
AAYRA.app/Contents/MacOS/AAYRA --dump          # print one round of readings
AAYRA.app/Contents/MacOS/AAYRA --render <dir>  # write panel/spinner PNG previews
AAYRA.app/Contents/MacOS/AAYRA --show-panel    # launch with the panel already open
```

## Notes
- Public IP comes from `https://api.ipify.org`. It is fetched when the panel opens and cached for 5 minutes; it is the only network request the app makes.
- Battery health is taken from `system_profiler` so it matches System Settings. CPU temperature isn't shown because Apple Silicon only exposes it through private APIs.
- Each spinner frame makes macOS re-snapshot the menu bar item, so the frame rate is capped (4–15 fps). Expect about 2–5 % CPU at normal load and about 8 % with all cores busy.
