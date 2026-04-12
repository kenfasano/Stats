# Stats

A custom macOS system-monitor dashboard built in **SwiftUI + Swift Charts**. It is a standalone floating window — not a menu-bar app — that displays real-time hardware, network, disk, and AI token-usage metrics in a frosted-glass card layout.

**Author:** Ken Fasano  
**Started:** January 2026  
**Language:** Swift (SwiftUI, Charts, IOKit, CoreWLAN, Metal, Network)  
**License:** *(not yet specified)*

---

## What It Looks Like

The app is a borderless, draggable window with a translucent (`.underWindowBackground`) frosted-glass backdrop. It shows a live clock in the header and a 2-column card grid below. Cards use `.ultraThinMaterial` with a soft shadow for depth.

---

## Dashboard Cards

| Card | What It Shows |
|---|---|
| **CPU Load** | Average utilization % with a 60-second area chart, top process name + CPU %, per-core bar chart (efficiency cores in red, performance cores in blue) |
| **GPU** | Utilization % with a 60-second area chart; GPU name sourced from IOAccelerator / Metal |
| **Network** | Download & upload rates (bytes/s) with separate area charts, Catmull-Rom smoothed |
| **Memory** | Donut chart segmented into App (active), Wired, Compressed, and Free; used/total GB string |
| **System & Network** | Disk volumes with progress bars and "% free (used / total GB)" labels; Wi-Fi RSSI & transmit rate; local IP; system uptime; Claude token usage section |
| **ScreenArt** | Scrollable text output of `~/Scripts/ScreenArt/results.txt`; lines colored black (OK) or red (error) based on ✓/✗ prefix symbols |

---

## Monitor Classes

Each monitor is an `ObservableObject` polled on a timer and injected into `ContentView` as `@StateObject`.

### `SystemMonitor`
- Reads per-core CPU load via `host_processor_info` (Mach kernel API), computing deltas between successive ticks.
- Computes average and per-core utilization each second.
- Reads RAM breakdown via `host_statistics64` (active, wired, compressor, free, inactive pages).
- Publishes a 60-sample `cpuHistory` array and `[RAMSegment]` for the donut chart.

### `GPUMonitor`
- Iterates `IOAccelerator` services via IOKit.
- Reads `PerformanceStatistics["Device Utilization %"]` (falls back to `"gpu-usage"` for older Intel drivers).
- GPU name sourced from `IOAccelerator` properties or `MTLCreateSystemDefaultDevice().name` as fallback.
- Updates every 1 second; maintains a 60-sample `gpuHistory`.

### `NetworkMonitor`
- Reads `getifaddrs` to sum bytes in/out across all non-loopback `AF_LINK` interfaces each second.
- Derives per-second download/upload rates from successive deltas.
- Reads Wi-Fi RSSI, noise, and transmit rate via `CWWiFiClient` (CoreWLAN).
- Resolves local IP from `en0`/`en1`.
- Maintains a 60-point `[NetworkPoint]` history (timestamped, for time-axis charts).

### `DiskMonitor`
- Enumerates mounted volumes via `FileManager.mountedVolumeURLs`, skipping hidden volumes.
- Filters to named volumes: `"Internal"` (path `/`) and `"Shared"` (path `/Volumes/Shared`).
- Reports total GB, available GB, and a `"% free (used / total GB)"` status string per volume.
- Reads system uptime from `kern.boottime` sysctl.
- Polls every 5 seconds.

### `ProcessMonitor`
- Shells out to `/bin/ps -Aceo pcpu,comm -r` to find the top CPU-consuming process.
- Parses process name and CPU% from the first non-header output line.
- Updates every 2 seconds.

### `WifiMonitor`
- Uses `NWPathMonitor` (Network framework) to track Wi-Fi connectivity state.
- Publishes `isConnected`, a status string, and an SF Symbol icon name.
- *(Note: detailed RSSI/rate data comes from `NetworkMonitor` via CoreWLAN, not this class.)*

### `ClaudeMonitor`
- Reads `~/.screenart_tokens.json`, a file written by ScreenArt's `token_tracker.py` script.
- Parses `today_input`, `today_output`, `month_input`, `month_output`, and `updated_at` fields.
- Formats token counts as raw numbers, `K` (thousands), or `M` (millions).
- Refreshes every 30 seconds.
- Displays a hint message (graceful empty state) if the file is absent.

### `ScreenArtMonitor`
- Reads `~/Scripts/ScreenArt/results.txt` every 60 seconds.
- Applies `AttributedString` styling: if the first line contains `✓`, text is rendered black; if `✗`, red.
- Strips the ✓/✗ symbols from the displayed text.

---

## App Structure

```
Stats/
├── StatsApp.swift          # @main entry; WindowGroup with hiddenTitleBar + contentSize resizability
├── ContentView.swift       # Root view; owns all @StateObject monitors; defines MetricCard,
│                           #   NetworkCard, CPUCoresChart, WindowDragGesture
├── SystemMonitor.swift     # CPU + RAM (Mach kernel APIs); RAMSegment + CPUCoresChart helper
├── GPUMonitor.swift        # IOAccelerator IOKit GPU utilization
├── NetworkMonitor.swift    # ifaddrs byte counters + CoreWLAN Wi-Fi stats
├── DiskMonitor.swift       # Mounted volume space + kern.boottime uptime
├── ProcessMonitor.swift    # /bin/ps top-process scraper
├── WifiMonitor.swift       # NWPathMonitor connectivity state
├── ClaudeMonitor.swift     # ~/.screenart_tokens.json token usage reader
├── ScreenArtMonitor.swift  # ~/Scripts/ScreenArt/results.txt display
└── VisualEffectView.swift  # NSViewRepresentable wrapper for NSVisualEffectView
```

---

## Key Design Decisions

**Floating borderless window.** `StatsApp.swift` uses `.hiddenTitleBar` and `.windowResizability(.contentSize)`. The window is draggable via a `DragGesture` on the header bar that repositions `NSApp.windows.first`.

**Frosted glass.** `VisualEffectView` wraps `NSVisualEffectView` with `.behindWindow` blending and `.underWindowBackground` material. Cards use `.ultraThinMaterial` on top.

**Charts.** The native Swift Charts framework is used throughout — `AreaMark`/`LineMark` for time-series (CPU, GPU, Network), `SectorMark` for the RAM donut, and `BarMark` for per-core CPU bars.

**CPU core color coding.** `CPUCoresChart` uses a heuristic: on 8-core chips the first 4 are efficiency cores (red); otherwise the first 2 are (red). Performance cores are blue.

**Status color thresholds.** CPU load header color is green below 50%, orange 50–80%, red above 80%.

---

## External Dependencies

This project uses **only Apple frameworks** — no third-party packages or Swift Package Manager dependencies.

| Framework | Used For |
|---|---|
| `SwiftUI` | All UI |
| `Charts` | All data visualizations |
| `IOKit` | GPU utilization via IOAccelerator |
| `Metal` | GPU name fallback (`MTLCreateSystemDefaultDevice`) |
| `CoreWLAN` | Wi-Fi RSSI, noise, transmit rate |
| `Network` | Wi-Fi connectivity state (`NWPathMonitor`) |
| `Darwin` / `Foundation` | Mach host APIs, sysctl, `getifaddrs`, timers |

---

## External File Dependencies

| File | Written By | Purpose |
|---|---|---|
| `~/.screenart_tokens.json` | ScreenArt `token_tracker.py` | Claude API token usage (today + month) |
| `~/Scripts/ScreenArt/results.txt` | ScreenArt scripts | Status text displayed in the ScreenArt card |

The app degrades gracefully when either file is absent — the Claude card shows a hint message and the ScreenArt card shows "Waiting for results...".

---

## Build & Run

Open `Stats.xcodeproj` in Xcode, select the **Stats** scheme, and run. No additional setup is required unless you want live data in the Claude or ScreenArt cards, which requires ScreenArt's Python scripts to be running separately.

**macOS target:** The project targets macOS (AppKit/SwiftUI Mac app). Minimum version is determined by the Xcode project settings.
