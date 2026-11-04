# AAYRA

**A tiny menu bar system monitor for macOS.** A turbine in the menu bar spins faster as your CPU works harder. Click it for a dashboard of CPU, storage, memory, battery and network, and click any card for the full details.

Native Swift and SwiftUI · Apple Silicon · macOS 15 or later · under 1 MB

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/hero-dark.png">
  <img alt="The AAYRA panel with the Battery details open beside it" src="docs/screenshots/hero-light.png">
</picture>

## Highlights

- 🌀 **Live turbine in the menu bar.** It spins slowly when the Mac is idle and speeds up with CPU load, adding motion blur above 80 %. With Reduce Motion on (or the animation turned off), it shows the CPU % as text instead. You can also add live ↑/↓ network speed as a second, compact menu bar item.
- 🗂 **Floating dashboard.** Cards float under the menu bar like Notification Center, on Liquid Glass in macOS 26 and later. Each card shows one big number with a bar or live chart.
- 🔎 **Details on click.** Click a card and a two-column detail panel opens beside it, on whichever side has room. The numbers update live, and you can select and copy any value. Header buttons jump straight to the right place: **Manage Storage…**, **Battery Settings…**, **Wi-Fi/Network Settings…** or **Activity Monitor**.
- 🔋 **Deep battery info.** Health and condition (matching System Settings), cycles, full-charge vs design capacity, live watts, voltage and current, per-cell voltages, adapter, and lifetime records (temperature range, peak currents, operating hours). It also shows who assembled the pack and who made the cells (e.g. Sunwoda / ATL), plus the estimated manufacture date and age.
- 💾 **Storage and SSD health.** Live disk read/write speed with a chart. NVMe SMART data: health %, spare capacity, temperature, power-on hours, unsafe shutdowns, media errors, and total data written and read. External drives, disk images and network shares are listed too, with free space, how they're connected (USB, Thunderbolt…) and an eject button.
- 🧠 **CPU and memory.** Usage history, per-core load grouped by Performance and Efficiency cores, chip and cache details, thermal state, and top processes by CPU and by memory. Helper processes are added up under their app's real name (e.g. *Visual Studio Code · 16*), like Activity Monitor. Memory shows app / wired / compressed / cached, pressure and swap.
- 🎮 **GPU.** Live GPU load with a history chart, split into renderer (pixels) and tiler (geometry) work, plus the unified memory the GPU is using and allocated, core count and GPU restarts. Read from the graphics driver, no admin rights needed. The card is off by default; turn it on in Settings → Sections.
- 🌐 **Network.** Live ↓/↑ speed chart, Wi-Fi name, signal, noise and SNR, channel and band, standard, security, local and public IP (click to copy), router, DNS and MAC. A **VPN** badge appears while a VPN is connected.
- ⚙️ **Settings.** Launch at Login, a keyboard shortcut to open the panel from any app, icon animation, CPU % and network speed in the menu bar, which cards to show, refresh rate (1, 2 or 5 s), temperature unit,, an optional update check (off by default), and an opt-out for the public IP lookup.
- 🪶 **Light.** About 2–4 % CPU while idling in the menu bar, and the whole app is under 1 MB.

## Install

1. Download **`AAYRA-<version>.zip`** from the [Releases](../../releases) page, or from the artifacts of the latest [Build](../../actions/workflows/build.yml) run.
2. Unzip it and drag **AAYRA.app** into **Applications**.
3. **Take it out of quarantine.** AAYRA is ad-hoc signed, not notarized by Apple, so macOS blocks it when it comes from the internet. You'll see something like *"Apple could not verify 'AAYRA' is free of malware"* or *"AAYRA is damaged and can't be opened"*. Open **Terminal** and run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/AAYRA.app
   ```

   This removes the "downloaded from the internet" flag from the app and everything inside it. You only need to do it once per download.

   Prefer not to use Terminal? Try to open AAYRA once, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the AAYRA message.
4. Open AAYRA. The turbine appears in the menu bar (there's no Dock icon). The first time the panel opens, macOS asks for Location Services access, which it requires before revealing the Wi-Fi name.

If you'd rather not run a downloaded app at all, [build it from source](#build-from-source). It takes about a minute.

## Screenshots

### Dashboard

| Light | Dark |
|:---:|:---:|
| <img src="docs/screenshots/panel-light.png" width="360" alt="Dashboard, light mode"> | <img src="docs/screenshots/panel-dark.png" width="360" alt="Dashboard, dark mode"> |

### Detail panels

| CPU | Memory |
|:---:|:---:|
| <img src="docs/screenshots/detail-cpu-dark.png" alt="CPU details: usage history, per-core load by cluster, chip, system and top processes"> | <img src="docs/screenshots/detail-memory-light.png" alt="Memory details: usage breakdown, hardware, pressure and swap, activity and top processes"> |
| **Storage** | **Network** |
| <img src="docs/screenshots/detail-storage-dark.png" alt="Storage details: space, volume, lifetime I/O, drive and SSD health"> | <img src="docs/screenshots/detail-network-light.png" alt="Network details: traffic chart, connection, Wi-Fi and addresses"> |

### Menu bar turbine

<img src="docs/screenshots/spinner.png" width="420" alt="Turbine animation frames, sharp and with motion blur">

The animation frames, sharp (top row) and with motion blur under heavy load (bottom row). The icon is a template image, so it follows light, dark and tinted menu bars.

> The screenshots are rendered by the app's debug renderer. In the real app the cards are Liquid Glass over your wallpaper. Serial numbers, MAC and IP addresses are replaced with placeholders.

## Using it

| Action | How |
|---|---|
| Open the dashboard | Click the turbine in the menu bar, or press **⌥⌘M** from any app (changeable in Settings) |
| Show details | Click any card. Click it again, or anywhere else, to close |
| Copy an IP address | Click it (it turns bold for a moment) |
| See an app's processes | Click an app in Top Processes (CPU or Memory) to expand it |
| Settings | Gear button in the footer, ⌘, or right-click the turbine |
| Close | Click outside, press Esc, or click the turbine |
| Quit | Power button in the footer, ⌘Q, or right-click the turbine |

## Build from source

Needs Xcode 26 or later (for the macOS 26 SDK) on an Apple Silicon Mac.

```bash
git clone <this repo> && cd AAYRA
./build-app.sh --open      # builds AAYRA.app here and launches it
```

An app you build yourself isn't quarantined, so the `xattr` step isn't needed. Move `AAYRA.app` to `/Applications` before turning on Launch at Login. The app icon is drawn in code. To change it, edit `scripts/make-icon.swift` and run `swift scripts/make-icon.swift`.

### Debug helpers

These are only included in debug builds, which keeps the release app small:

```bash
swift build
BIN="$(swift build --show-bin-path)/AAYRA"
"$BIN" --dump              # print one round of readings, to compare with system tools
"$BIN" --render <dir>      # write PNG previews (these screenshots); AAYRA_RENDER_SECONDS=60 for fuller charts
```

`AAYRA.app/Contents/MacOS/AAYRA --show-panel` launches the release app with the panel open.

### Tests

```bash
swift test
```

The tests in `Tests/AAYRATests` cover the parts that turn raw system data into what you see:
- battery manufacture-date decoding, pack-assembler lookup and cell-maker parsing;
- size, rate and time formats;
- version comparison for the update check;
- process naming, Wi-Fi signal quality and keyboard-shortcut choices.

They use Swift Testing and finish in under a second.

### Project layout

| Folder | What's there |
|---|---|
| `Sources/AAYRA/Providers` | Reading the system: CPU, GPU, memory, disks, volumes, battery, network, processes |
| `Sources/AAYRA/Views/Sections` | One file per section (CPU, GPU, Storage, Memory, Battery, Network), each with its card and its detail panel |
| `Sources/AAYRA/Views/Panel` | The floating panel and its header and footer |
| `Sources/AAYRA/Views/Detail` | Building blocks shared by all detail panels |
| `Sources/AAYRA/Views` | Shared components, Settings, the turbine frames |
| `Sources/CNVMe` | Small C helper for NVMe SMART data |

## Continuous integration

GitHub Actions ([`.github/workflows/build.yml`](.github/workflows/build.yml)) builds the app on a macOS 26 runner for every push and pull request:

- Runs the unit tests first. If any fail, nothing is built or released.
- Builds the release app with `./build-app.sh`, reports its size in the run summary, and keeps `AAYRA-<version>.zip` as a downloadable artifact.
- **Releases:** set the version in `Resources/Info.plist`, commit, then push a matching tag. The build checks that the tag matches the version, then publishes a GitHub Release with the zip attached.

  ```bash
  git tag -a v1.3 -m "AAYRA 1.3" && git push origin v1.3
  ```

## Privacy and notes

- **Network use.** AAYRA makes at most two kinds of request, and you control both:
  - **Public IP lookup** at `https://api.ipify.org`. It runs when the panel opens, is cached for 5 minutes, and can be turned off in Settings → Privacy.
  - **Update check** at `https://api.github.com` (this repo's latest release). It's **off by default**: it runs only if you click **Check Now** or turn on **Check for updates automatically** (then at most once a day). It sends nothing about you or your Mac, and never downloads or installs anything. When a newer version exists, a badge appears in the panel footer linking to the release page.
- **Wi-Fi name.** macOS only reveals the Wi-Fi name to apps with Location Services access, so AAYRA asks once. Nothing is recorded or sent.
- **No CPU temperature.** Apple Silicon only exposes it through private APIs. Battery and SSD temperatures are shown.
- **Battery health** is read from `system_profiler`, so it matches System Settings. The pack assembler comes from the serial-number prefix, and the cell maker from the battery's own manufacturer data.
- **CPU cost.** Each turbine frame makes macOS re-snapshot the menu bar item, so the frame rate is capped at 4–15 fps.

## Versions

- **Unreleased.** Optional update check against GitHub Releases (off by default). GPU card and detail panel (off by default). External drives and other volumes in Storage, with eject. Global keyboard shortcut (⌥⌘M by default) to open the panel. Top Processes rows expand to show an app's individual processes (one at a time). Detail panels respond to the first click and scroll when taller than the screen.
- **1.3.** Quick-action buttons in detail panels (Manage Storage, Battery and Wi-Fi settings, Activity Monitor), processes grouped under their app's real name, live disk read/write speed, VPN indicator, optional network speed in the menu bar, author and links in Settings, scrolling detail panels on small screens, and charts and background refreshes that follow the refresh-rate setting.
- **1.2.** Floating dashboard with big numbers, click-to-open detail panels, Settings window, SSD SMART health, deep battery details, redesigned per-core view, Control Center–style visuals.
