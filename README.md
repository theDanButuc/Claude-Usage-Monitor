# ClaudeUsageMonitor · v2.0.0

A native macOS menu-bar app that tracks your [Claude.ai](https://claude.ai) usage in real time — no API key needed.

<img src="ClaudeUsageMonitor/Assets/AppIcon_128.png" width="128" alt="App Icon" />

---

## Demo

<img src="screenshots/recording.gif" alt="ClaudeUsageMonitor demo" />

<img src="screenshots/Screenshot.png" width="260" alt="ClaudeUsageMonitor popover" />

---

## Features

- **Menu-bar only** — no Dock icon, stays out of your way
- **Burn rate display** — menu bar shows estimated time left (`~45min left | 42%`) based on actual usage pace; falls back to percentage when idle
- **Colour-coded icon** — green → orange → red as usage climbs
- **Three-bar dashboard** — separate horizontal bars for Current session, Weekly limits (all models), and Sonnet-specific usage (Max plan)
- **Extra usage tracking** — displays monthly credit spend progress when Extra Usage is enabled on your account
- **Direct API** — reads data straight from Claude's internal API; no DOM scraping, no JS injection
- **Reset countdowns** — "Resets in X hr Y min" for the session window; "Resets [Day] [Time]" for weekly limits
- **Configurable auto-refresh** — 30s / 1m / 2m / 5m / 10m, set via right-click menu
- **Native notifications** — contextual alerts at 75%, 80%, 90%, 95%, 100% usage and on session reset
- **Smart tip banner** — in-popover tip that updates as usage climbs (75→80→90→95%)
- **Stale data indicator** — icon turns grey and shows ⚠ if data is older than 10 minutes
- **Right-click context menu** — quick usage info and settings without opening the popover
- **In-app update banner** — notified when a new version is available on GitHub
- **Persisted login** — you only log in once; session is reused automatically

---

## Installation (recommended — pre-built DMG)

> **Requires macOS 13 Ventura or later.**

### Step 1 — Download

Download the latest **ClaudeUsageMonitor.dmg** from the [Releases page](https://github.com/theDanButuc/Claude-Usage-Monitor/releases/latest).

### Step 2 — Install

1. Double-click `ClaudeUsageMonitor.dmg` to mount it
2. Drag **ClaudeUsageMonitor** into the **Applications** folder shortcut

### Step 3 — First launch (Gatekeeper bypass)

Because the app is **ad-hoc signed** (not yet notarized with an Apple Developer ID), macOS will block it on first open.

**Do this once:**

```
Right-click ClaudeUsageMonitor.app → Open → Open
```

Or via Terminal:

```bash
xattr -cr /Applications/ClaudeUsageMonitor.app
open /Applications/ClaudeUsageMonitor.app
```

> You will **not** need to do this again after the first successful launch.

### Step 4 — Log in to Claude

A browser window opens automatically on first run. Log in to your Claude.ai account normally. The window closes by itself when login succeeds and the app icon appears in your menu bar.

### Homebrew (alternative)

```bash
brew tap theDanButuc/tap
brew install --cask claude-usage-monitor
```

---

## Usage

| Element | Meaning |
|---------|---------|
| **Green** `12% \| 24%` | Plenty of messages left (< 50 % used) |
| **Orange** `~45min left \| 62%` | Burn rate active — estimated time left shown |
| **Red** `~8min left \| 91%` | Almost out — act fast |
| **Grey** `⚠ ~45min left \| 24%` | Data is stale (last update > 10 min ago) |

The left value shows **estimated time left** (burn rate) when active, or **Current session %** when idle. The right value is always **Weekly limits %**.

**Left-click** the icon to open the popover:

- **Plan usage limits** section with progress bars:
  - **Current session** — rate-limit window usage with "Resets in X hr Y min" countdown
  - **Weekly limits / All models** — billing-period usage with reset day and time (e.g. "Resets Fri 10:00 AM")
  - **Sonnet** — Sonnet-specific weekly usage (Max plan only)
  - **Extra usage** — monthly credit spend bar (X of Y credits), shown only when Extra Usage is enabled on your account
- **Refresh button** (↻) — force an immediate refresh
- **Quit button** — exit the app

**Right-click** the icon for a quick context menu:

- Current usage and reset countdown at a glance
- **Refresh Interval** submenu — choose 30s / 1m / 2m / 5m / 10m (persisted across launches)
- **Refresh Now** — immediate refresh
- **Quit**

---

## Building from source

You need **Xcode Command Line Tools** (free) — full Xcode is not required.

```bash
xcode-select --install   # if not already installed
```

Clone and build:

```bash
git clone https://github.com/theDanButuc/Claude-Usage-Monitor.git
cd Claude-Usage-Monitor

bash scripts/build.sh             # native arch (arm64 or x86_64)
bash scripts/build.sh --universal # universal binary (arm64 + x86_64)
```

Produces `dist/ClaudeUsageMonitor-vX.X.X.dmg` ready to install.

### Regenerate the app icon

```bash
swift scripts/make_icon.swift
# Produces /tmp/AppIcon.icns — copy to ClaudeUsageMonitor/Assets/AppIcon.icns
```


---

## How it works

### Data source

The app calls Claude's internal REST API directly:

- `GET /api/organizations` — resolves your organisation ID (cached after first call)
- `GET /api/organizations/{org_id}/usage` — returns utilization percentages and reset timestamps for all windows (`five_hour`, `seven_day`, `seven_day_sonnet`, `extra_usage`)

Auth is via the `sessionKey` cookie, extracted from the login WKWebView after OAuth and stored in `UserDefaults`. All subsequent requests are plain `URLSession` calls — no WKWebView or JS injection at runtime.

### Session persistence

On first launch a browser window opens so you can log in to Claude.ai. The `sessionKey` cookie is extracted and stored locally. If the session expires, the login window reappears automatically.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Cannot be opened because the developer cannot be verified" | Right-click → Open, or run `xattr -cr /Applications/ClaudeUsageMonitor.app` |
| Login window keeps appearing | Your Claude session expired — log in again |
| All bars show 0% | Session key may be invalid — quit, delete the app from Applications, reinstall and log in again |
| Sonnet bar not visible | Only shown on Max plan accounts |
| Extra usage bar not visible | Only shown when Extra Usage is enabled on your Claude account |
| Icon missing from menu bar | Quit via the popover's Quit button and re-open the app |
| App won't launch after macOS update | Rebuild from source with the updated SDK |

---

## Project structure

```
ClaudeUsageMonitor/
├── ClaudeUsageMonitor/
│   ├── ClaudeUsageMonitorApp.swift   # @main entry point
│   ├── AppDelegate.swift             # Status bar, popover, refresh timer
│   ├── LoginWindowController.swift   # Full-screen login WebView
│   ├── Models/
│   │   └── UsageData.swift           # Data model + computed helpers
│   ├── Services/
│   │   ├── ClaudeAPIService.swift    # URLSession-based API client (replaces WebScrapingService)
│   │   ├── NotificationService.swift # Usage threshold & reset notifications
│   │   └── UpdateService.swift       # GitHub Releases update check
│   ├── Views/
│   │   ├── ContentView.swift         # Popover UI (two-bar dashboard)
│   │   └── CircularProgressView.swift
│   ├── Assets/
│   │   └── AppIcon.icns              # All 10 icon sizes
│   ├── Info.plist
│   └── ClaudeUsageMonitor.entitlements
├── scripts/
│   ├── build.sh                       # Local build + DMG script
│   └── make_icon.swift               # Icon generator (Swift script)
├── screenshots/
│   └── popover.png                   # App screenshot
├── .github/workflows/
│   ├── release.yml                   # CI: build & publish DMG on git tag
│   └── update-homebrew-tap.yml       # CI: update Homebrew cask after release
├── project.yml                        # XcodeGen spec
└── .gitignore
```

---

## Requirements

- macOS 13 Ventura or later
- An active Claude.ai account (Free, Pro, Team, or Max)
- Internet connection

---

## License

MIT License. Feel free to use Claude Usage Monitor and contribute.

---

## Acknowledgements

- **[DukeOfCheese](https://github.com/DukeOfCheese)** — proposed the migration from DOM scraping to direct API calls, the Sonnet usage bar, and the extra usage bar ([PR #3](https://github.com/theDanButuc/Claude-Usage-Monitor/pull/3)). These ideas shaped v2.0.0.
