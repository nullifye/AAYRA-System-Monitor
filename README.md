# AAYRA

**A tiny menu bar system monitor for macOS.** A turbine in the menu bar spins faster as your CPU works harder. Click it for a dashboard of CPU, storage, memory, battery and network, and click any card for the full details.

Native Swift and SwiftUI · Apple Silicon · macOS 15 or later · about 1.2 MB

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/hero-dark.png">
  <img alt="The AAYRA panel with the Battery details open beside it" src="docs/screenshots/hero-light.png">
</picture>

## Highlights

- 🌀 **Live turbine in the menu bar.** It spins slowly when the Mac is idle and speeds up with CPU load, adding motion blur above 80 %. With Reduce Motion on (or the animation turned off), it shows the CPU % as text instead. You can also add live ↑/↓ network speed as a second, compact menu bar item.
- 🗂 **Floating dashboard.** Cards float under the menu bar like Notification Center, on Liquid Glass in macOS 26 and later. Each card shows one big number with a bar or live chart.
- 🔎 **Details on click.** Click a card and a two-column detail panel opens beside it, on whichever side has room. The numbers update live, and you can select and copy any value. Header buttons jump straight to the right place: **Manage Storage…**, **Battery Settings…**, **Wi-Fi/Network Settings…** or **Activity Monitor**.
- 📈 **An hour of history.** The CPU, GPU and Network detail charts switch between the last **1 minute, 10 minutes or 1 hour**, with peak and average for the chosen range. History is recorded in the background, even while the panel is closed; GPU history starts when its card is enabled.
- 🔋 **Deep battery info.** Health and condition (matching System Settings), cycles, full-charge vs design capacity, live watts, voltage and current, per-cell voltages, adapter, and lifetime records (temperature range, peak currents, operating hours). It also shows who assembled the pack and who made the cells (e.g. Sunwoda / ATL), plus the estimated manufacture date and age. If the battery keeps draining while AC is connected, AAYRA points it out and shows whether the adapter may be underpowered or the cause is unknown. Optional alerts for AC drain and sustained battery heat are in Settings → Alerts.
- 💾 **Storage and SSD health.** Live disk read/write speed with a chart. NVMe SMART data: health %, spare capacity, temperature, power-on hours, unsafe shutdowns, media errors, and total data written and read. External drives, disk images and network shares are listed too, with free space, how they're connected (USB, Thunderbolt…) and an eject button.
- 🧠 **CPU and memory.** Usage history, per-core load grouped by Performance and Efficiency cores, chip and cache details, thermal state, and top processes by CPU and by memory. Helper processes are added up under their app's real name (e.g. *Visual Studio Code · 16*), like Activity Monitor. Memory shows app / wired / compressed / cached, pressure and swap.
- 🎮 **GPU.** Live GPU load with 1m / 10m / 1h history, split into renderer (pixels) and tiler (geometry) work, plus the unified memory the GPU is using and allocated, its share of system RAM, core count, GPU restarts and system thermal state. Read from the graphics driver, no admin rights needed. The card is off by default; turn it on in Settings → Sections.
- 🌐 **Network.** Live ↓/↑ speed chart, Wi-Fi name, signal, noise and SNR, channel and band, standard, security, local and public IP (click to copy), router, DNS and MAC. A **VPN** badge appears while a VPN is connected.
- ✨ **Agent Usage (optional).** A separate menu-bar icon opens its own floating panel with remaining-allowance bars, reset times, and today's locally recorded token counts, independently of the hardware panel. Click an agent's card for today's usage by model, by token type (fresh input, cache read/write, output, reasoning) and, optionally, by project, plus account details such as the plan, Claude usage credits, Codex feature limits and Copilot premium request counts. Tap the gear beside Refresh to tick which agents to show: Claude Code, Codex, GitHub Copilot and OpenCode (account limits plus local tokens), Gemini CLI, Qwen Code, Cline, Roo Code, Kilo Code, Kimi, Pi, Oh My Pi, Cherry Studio and ZCode (local tokens), and Perch AI (context fill). Drag the rows to reorder them; the same order sets the cards in the panel. The first three agents found on this Mac, plus Perch AI when it has threads, are ticked by default; unticked agents are not read at all. Token totals are separate from account allowance and can miss other devices or pruned logs. **Perch AI** appears as its own card and shows the Perch CLI's context fill instead: how much of a thread's model window is in use, read from the `~/.perch/threads` snapshots the CLI already writes, newest thread first. Perch keeps no per-request token ledger and exposes no readable quota, so the card reports a share of the window rather than spend, and reading it costs no tokens. The panel fits its content when the screen has room and scrolls only when needed. Off by default in Settings → Menu Bar. When open, it automatically tries existing Claude Code and Codex credentials, an OpenCode Go key, and an existing GitHub credential for Copilot; no separate AAYRA login is required. Codex can fall back to a recent local rate-limit snapshot, and OpenCode can use its CLI experimental API if no Go key exists. Missing, expired, unsupported, or unauthorized limits are shown as unavailable. A 429 from an account usage endpoint is throttling, not exhausted allowance; AAYRA backs off before retrying.
- 🔔 **Optional health alerts.** Get a macOS notification for an SSD SMART warning or when a previously seen VPN connection disappears while the network remains online. Alerts are off by default and rate-limited.
- 🔔 **Optional alerts.** You can turn on macOS notifications for a low battery, the startup disk nearly full, high memory pressure, or the CPU staying above 90% for several minutes. Each alert has its own threshold and is off by default. An alert fires once and waits until things are back to normal before it can fire again. Memory and CPU alerts name the app responsible, and clicking an alert opens the panel.
- 📋 **Diagnostic snapshot.** Export a human-readable `.txt` summary of the current readings from the panel footer for troubleshooting. The save dialog offers separate, initially unchecked choices for IP addresses, serial numbers and process names. Wi-Fi names, MAC addresses, volume names and file paths are never exported; AAYRA does not upload the report or fetch anything for the export. Review the file before sharing it.
- ⚙️ **Settings.** Launch at Login, a keyboard shortcut to open the panel from any app, icon animation, CPU % and network speed in the menu bar, which cards to show, refresh rate (1, 2 or 5 s), temperature unit,, an optional update check (off by default), and an opt-out for the public IP lookup.
- 🪶 **Light.** About 2–4 % CPU while idling in the menu bar, and the whole app is about 1.2 MB.

## Install

### With Homebrew

```bash
brew tap nullifye/aayra https://github.com/nullifye/AAYRA-System-Monitor
brew install --cask nullifye/aayra/aayra
```

Using the full name (`nullifye/aayra/aayra`) tells Homebrew to trust just this cask, as Homebrew 6 and later require for third-party taps. To install with the short name `brew install --cask aayra`, run `brew trust --cask nullifye/aayra/aayra` once first.

The cask removes the quarantine flag for you, so AAYRA opens straight away. Update it with `brew upgrade --cask aayra`. Remove it with `brew uninstall --cask aayra`, or add `--zap` to delete its settings too.

### Manually

1. Download **`AAYRA-<version>.zip`** from the [Releases](../../releases) page, or from the artifacts of the latest [Build](../../actions/workflows/ci.yml) run.
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
| <img src="docs/screenshots/detail-cpu-dark.png" alt="CPU details: usage chart with a 1m / 10m / 1h range, average and peak, per-core load by cluster, chip, system and top apps"> | <img src="docs/screenshots/detail-memory-light.png" alt="Memory details: usage breakdown, hardware, pressure and swap, activity and top processes"> |
| **Storage** | **Network** |
| <img src="docs/screenshots/detail-storage-dark.png" alt="Storage details: space, live disk activity, lifetime I/O, drive, SSD health, volume and other volumes"> | <img src="docs/screenshots/detail-network-light.png" alt="Network details: traffic chart with a 1m / 10m / 1h range, connection and VPN status, Wi-Fi and addresses"> |

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
| Change a chart's time range | Use the **1m / 10m / 1h** switch above the CPU and Network charts |
| Turn on alerts | Settings → Alerts (each one is off until you turn it on) |
| Export diagnostics | Share button in the panel footer; choose any sensitive details explicitly in the save dialog |
| Settings | Gear button in the footer, ⌘, or right-click the turbine |
| Close | Click outside, press Esc, or click the turbine |
| Quit | Power button in the footer, ⌘Q, or right-click the turbine |

In Agent Usage → gear → Show Agents, tap an eye to replace the sparkle menu-bar icon with an agent’s percentage. Select up to three agents; their percentages follow the list order. Account agents show their lowest remaining allowance, and Perch shows context used. Agents with only token counts have no percentage. Hide all percentages to restore the sparkle icon.

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

### Formatting

Code style is defined in `.swift-format`: 4-space indents and lines up to 130 characters. CI rejects code that doesn't match. To fix formatting before you commit:

```bash
swift format format --in-place --recursive Sources Tests
```

### Tests

```bash
swift test
```

The tests in `Tests/AAYRATests` cover the parts that turn raw system data into what you see:
- battery manufacture-date decoding, pack-assembler lookup and cell-maker parsing;
- size, rate and time formats;
- version comparison for the update check;
- process naming, Wi-Fi signal quality and keyboard-shortcut choices;
- the alert rules (thresholds, how long a condition must last, re-arming and cooldowns), driven with simulated time;
- the hour of chart history (trimming, bucket averages, gaps, and buckets that stay put as time moves).

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

GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs for every push and pull request. The workflow is read-only; only the release job can write.

- **`build`** (macOS 26 runner):
  - checks formatting against `.swift-format`;
  - runs the unit tests;
  - builds the release app with `./build-app.sh` and reports its size in the run summary;
  - keeps `AAYRA-<version>.zip` as a downloadable artifact.

  If any step fails, nothing is released.
- **`release`** (Linux runner, version tags only): checks that the tag matches the version in `Resources/Info.plist`, then publishes a GitHub Release with the zip from `build`.
- **To release:** set the version in `Resources/Info.plist`, commit, then push a matching tag.

  ```bash
  git tag -a v1.8 -m "AAYRA 1.8" && git push origin v1.8
  ```
- **Homebrew:** once CI has published the release, point the cask at it, then commit and push:

  ```bash
  scripts/update-cask.sh            # reads the version from Info.plist, downloads the zip, writes its SHA-256
  git commit -m "Homebrew cask: AAYRA 1.8" Casks/aayra.rb && git push
  ```

## Privacy and notes

- **Network use.** Outside the optional Agent Usage panel described below, AAYRA makes these requests:
  - **Public IP lookup** at `https://api.ipify.org`. It runs when the panel opens, is cached for 5 minutes, and can be turned off in Settings → Privacy.
  - **Update check** at `https://api.github.com` (this repo's latest release). It's **off by default**: it runs only if you click **Check Now** or turn on **Check for updates automatically** (then at most once a day). It sends nothing about you or your Mac, and never downloads or installs anything. When a newer version exists, a badge appears in the panel footer linking to the release page.
- **Agent Usage.** This separate menu-bar item is off by default. When its panel is open, AAYRA reads existing access tokens only in memory: Claude Code's macOS Keychain (or legacy credential file), Codex's `~/.codex/auth.json`, OpenCode Go's `~/.local/share/opencode/auth.json`, and an existing Copilot/GitHub token from the environment or `gh auth token`. It sends each only to its own fixed usage endpoint (`api.anthropic.com`, `chatgpt.com`, `opencode.ai`, `api.github.com`) at most once every five minutes for Claude and every two minutes for the others, however often the panel is opened or refreshed (this pacing survives relaunches). On HTTP 429 it backs off, keeps showing the last good numbers marked with when they were checked, and for Codex uses a recent local rate-limit snapshot when one exists. Only those percentages, reset times and pacing dates are kept in AAYRA's preferences; tokens never are. Claude’s Keychain may prompt. A generic GitHub token may lack Copilot permission; in that case Copilot stays unavailable. No tokens are saved, logged, or refreshed by AAYRA; expired credentials require signing in through the provider app. Locally observed token totals come only from files the agents already write on this Mac: Claude Code, Codex, Qwen Code, Pi and Oh My Pi JSONL; Gemini CLI chat recordings; VS Code Copilot Chat session logs; Cline, Roo Code and Kilo Code task logs (VS Code, Cursor, Windsurf) and the Cline CLI; Kimi `wire.jsonl`; Cherry Studio agent transcripts; and OpenCode, Kilo CLI and ZCode SQLite databases opened read-only. Records without their own timestamp are skipped rather than dated by file time. Only counts, model names and (for Claude Code, Codex, Copilot and OpenCode) working-folder paths are kept, in memory; session text is not retained or sent. Usage by project is off by default (Show Agents → Options) so folder names don't appear in screenshots. Agents unticked with the panel's gear button are not read, and their account endpoints are not contacted. Tools that keep only running per-session totals (Goose, Factory Droid, Hermes), compressed or server-side history (Zed, OpenClaw, Amp), or no token data (Crush) are not supported, because a reliable "today" count can't be derived from them. With no Codex OAuth token, AAYRA also scans a recent session file for rate-limit events. With no OpenCode Go key, it may invoke the installed OpenCode CLI's experimental limits API. It never derives account quota from local token totals or OpenCode's estimated local spend. While the panel is closed, only agents selected with the eye control for menu-bar percentages refresh (every two minutes, with the same provider pacing); local token logs are not scanned in the background. The Perch card reads only the context snapshots the Perch CLI writes under `~/.perch/threads` (or `$PERCH_CLI_STATE_DIR`): token counts, the model label, the context categories and the thread's own last objective, kept in memory. It makes no network request, reads no Perch credential, and spends no Perch tokens; message text is not retained.
- **Wi-Fi name.** macOS only reveals the Wi-Fi name to apps with Location Services access, so AAYRA asks once. Nothing is recorded or sent.
- **No CPU temperature.** Apple Silicon only exposes it through private APIs. Battery and SSD temperatures are shown.
- **Battery health** is read from `system_profiler`, so it matches System Settings. The pack assembler comes from the serial-number prefix, and the cell maker from the battery's own manufacturer data.
- **CPU cost.** Each turbine frame makes macOS re-snapshot the menu bar item, so the frame rate is capped at 4–15 fps.

## Versions

- **1.8.** Optional Agent Usage panel with its own menu-bar icon: account limits for Claude Code, Codex, GitHub Copilot and OpenCode, and today's local token counts for 15 agents (adding Gemini CLI, Qwen Code, Cline, Roo Code, Kilo Code, Kimi, Pi, Oh My Pi, Cherry Studio, ZCode and Perch's context fill). Choose agents with the gear button; the first three found on this Mac are shown by default and unticked agents aren't read. Click a card for usage by model, by token type and, optionally, by project, plus plans, Claude usage credits, Codex feature limits and Copilot premium request counts. Account checks are paced (5 min for Claude, 2 min for others) and keep the last good numbers when a service is busy.
- **1.7.** Optional SSD SMART, sustained battery heat and VPN-disconnect alerts. Privacy-scrubbed diagnostic snapshot export with explicit opt-ins for IP addresses, serial numbers and process names. GPU detail charts now offer 1m / 10m / 1h history, average and peak, plus memory share and system thermal state. Menu-bar CPU text stays steady as the percentage changes.
- **1.6.** CPU and Network charts with 1m / 10m / 1h history. Optional alerts for low battery, nearly-full disk, high memory pressure and long CPU load. CI split into build and release jobs, with a format check. The CPU detail panel uses about half the CPU it did while open.
- **1.5.** Install with Homebrew (`brew install --cask nullifye/aayra/aayra`). The panel and Settings window open without taking focus from the app you're using, and switching apps closes the panel.
- **1.4.** Optional update check against GitHub Releases (off by default). GPU card and detail panel (off by default). External drives and other volumes in Storage, with eject. Global keyboard shortcut (⌥⌘M by default) to open the panel. Top Processes rows expand to show an app's individual processes (one at a time). Detail panels respond to the first click and scroll when taller than the screen.
- **1.3.** Quick-action buttons in detail panels (Manage Storage, Battery and Wi-Fi settings, Activity Monitor), processes grouped under their app's real name, live disk read/write speed, VPN indicator, optional network speed in the menu bar, author and links in Settings, scrolling detail panels on small screens, and charts and background refreshes that follow the refresh-rate setting.
- **1.2.** Floating dashboard with big numbers, click-to-open detail panels, Settings window, SSD SMART health, deep battery details, redesigned per-core view, Control Center–style visuals.
