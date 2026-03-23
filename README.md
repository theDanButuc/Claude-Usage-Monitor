# ClaudeUsageMonitor

A native macOS menu-bar app that tracks your [Claude.ai](https://claude.ai) usage in real time — no API key needed.

<img src="ClaudeUsageMonitor/Assets/AppIcon_128.png" width="128" alt="App Icon" />

---

## Features

- **Menu-bar only** — no Dock icon, stays out of your way
- **Live usage counter** — shows `used/limit` (e.g. `45/100`) right in the menu bar
- **Colour-coded tree icon** — green → yellow → red as usage climbs
- **Popover dashboard** — circular progress ring, reset countdown, stats cards
- **Session-aware** — captures Claude's internal rate-limit window via a fetch interceptor, not just the billing-period total
- **Auto-refresh** every 5 minutes; manual Refresh button in the popover
- **Persisted login** — WebKit stores your Claude session automatically; you only log in once

---

## Installation (recommended — pre-built DMG)

> **Requires macOS 13 Ventura or later.**

### Step 1 — Download

Download **[ClaudeUsageMonitor.dmg](dist/ClaudeUsageMonitor.dmg)** from the `dist/` folder in this repository.

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

A browser window opens automatically on first run. Log in to your Claude.ai account normally. The window closes by itself when login succeeds and the tree icon appears in your menu bar.

---

## Usage

| Element | Meaning |
|---------|---------|
| 🌲 **Green** `45/100` | Plenty of messages left (< 50 % used) |
| 🌲 **Yellow** `67/100` | Getting there (50 – 80 % used) |
| 🌲 **Red** `88/100` | Almost out (> 80 % used) |

Click the icon to open the popover:

- **Circular ring** — current session usage percentage
- **Resets in X h Y m** — time until the next usage window resets
- **Period total card** — billing-period total (when session data is available separately)
- **Rate limit badge** — Normal / Limited
- **Refresh button** (↻) — force an immediate scrape
- **Quit button** — exit the app

---

## Building from source

You need **Xcode Command Line Tools** (free) — full Xcode is not required.

```bash
xcode-select --install   # if not already installed
```

Clone and build:

```bash
git clone https://github.com/theDanButuc/Claude-Usage-Monitor.git
cd ClaudeUsageMonitor

# Compile
swiftc \
  -sdk $(xcrun --show-sdk-path --sdk macosx) \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework WebKit -framework SwiftUI -framework Combine \
  -O -module-name ClaudeUsageMonitor \
  -o build/ClaudeUsageMonitor \
  ClaudeUsageMonitor/ClaudeUsageMonitorApp.swift \
  ClaudeUsageMonitor/AppDelegate.swift \
  ClaudeUsageMonitor/LoginWindowController.swift \
  ClaudeUsageMonitor/Models/UsageData.swift \
  ClaudeUsageMonitor/Services/WebScrapingService.swift \
  ClaudeUsageMonitor/Views/CircularProgressView.swift \
  ClaudeUsageMonitor/Views/ContentView.swift

# Package into .app
mkdir -p build/ClaudeUsageMonitor.app/Contents/{MacOS,Resources}
cp build/ClaudeUsageMonitor     build/ClaudeUsageMonitor.app/Contents/MacOS/
cp ClaudeUsageMonitor/Info.plist build/ClaudeUsageMonitor.app/Contents/
cp ClaudeUsageMonitor/Assets/AppIcon.icns build/ClaudeUsageMonitor.app/Contents/Resources/

# Sign (ad-hoc)
codesign --force --deep --sign - \
  --entitlements ClaudeUsageMonitor/ClaudeUsageMonitor.entitlements \
  --options runtime \
  build/ClaudeUsageMonitor.app

# Run
open build/ClaudeUsageMonitor.app
```

### Rebuild the DMG

```bash
brew install create-dmg   # one-time

create-dmg \
  --volname "Claude Usage Monitor" \
  --volicon "build/ClaudeUsageMonitor.app/Contents/Resources/AppIcon.icns" \
  --window-size 540 380 --icon-size 128 \
  --icon "ClaudeUsageMonitor.app" 130 190 \
  --app-drop-link 400 190 \
  --no-internet-enable \
  dist/ClaudeUsageMonitor.dmg \
  build/ClaudeUsageMonitor.app
```

### Regenerate the app icon

```bash
swift scripts/make_icon.swift
# Produces /tmp/AppIcon.icns — copy to ClaudeUsageMonitor/Assets/AppIcon.icns
```

### Open in Xcode (optional)

```bash
brew install xcodegen
xcodegen generate          # creates ClaudeUsageMonitor.xcodeproj
open ClaudeUsageMonitor.xcodeproj
```

---

## How it works

### Data source

The app embeds a hidden `WKWebView` that loads `claude.ai/settings/usage` using your stored browser session (via `WKWebsiteDataStore.default()` — the same cookie store Safari uses for WebKit-based apps).

A JavaScript **fetch/XHR interceptor** is injected at document start, before any page script runs. It captures every API response that mentions usage, limits, or quotas and forwards the raw JSON to Swift. This gives session-window data (e.g. the 5-hour rate-limit window) not visible in the page's DOM text. A DOM-text extraction pass runs 2.5 s after page load as a fallback.

### Cookie persistence

`WKWebsiteDataStore.default()` persists cookies to disk between app launches automatically — no manual Keychain work needed. If the session expires, the login window reappears.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Cannot be opened because the developer cannot be verified" | Right-click → Open, or run `xattr -cr /Applications/ClaudeUsageMonitor.app` |
| Login window keeps appearing | Your Claude session expired — log in again |
| Shows `0/0` or no numbers | Claude.ai's page changed; open a GitHub Issue with your macOS version |
| Icon missing from menu bar | Quit via the popover's Quit button and re-open the app |
| App won't launch after macOS update | Rebuild from source with the updated SDK |

---

## Project structure

```
ClaudeUsageMonitor/
├── ClaudeUsageMonitor/
│   ├── ClaudeUsageMonitorApp.swift   # @main entry point
│   ├── AppDelegate.swift             # Status bar, popover, timer
│   ├── LoginWindowController.swift   # Full-screen login WebView
│   ├── Models/
│   │   └── UsageData.swift           # Data model + computed helpers
│   ├── Services/
│   │   └── WebScrapingService.swift  # WKWebView + JS interceptor
│   ├── Views/
│   │   ├── ContentView.swift         # Popover UI
│   │   └── CircularProgressView.swift
│   ├── Assets/
│   │   └── AppIcon.icns              # All 10 icon sizes
│   ├── Info.plist
│   └── ClaudeUsageMonitor.entitlements
├── scripts/
│   └── make_icon.swift               # Icon generator (Swift script)
├── dist/
│   └── ClaudeUsageMonitor.dmg        # Pre-built installer
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

MIT — use freely, attribution appreciated.
