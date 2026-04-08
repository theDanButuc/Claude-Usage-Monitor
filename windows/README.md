# ClaudeUsageMonitor — Windows Port

A Windows system-tray application that tracks your [Claude.ai](https://claude.ai) usage in real time — no API key needed.

This is a Python port of the native macOS app. It provides the same core features using Windows-compatible libraries:

| macOS (Swift) | Windows (Python) |
|---|---|
| `NSStatusBar` / `NSStatusItem` | `pystray` |
| `NSPopover` + SwiftUI | `tkinter` |
| `WKWebView` + `WKWebsiteDataStore` | Playwright (Chromium, persistent context) |
| `UserNotifications` | `winotify` |
| `UserDefaults` | JSON settings file |

---

## Requirements

- **Python 3.11+**
- **Windows 10 or 11**
- An active Claude.ai account (Free, Pro, Team, or Max)
- Internet connection

---

## Installation

### Step 1 — Install Python dependencies

```powershell
cd windows
pip install -r requirements.txt
```

### Step 2 — Install the Playwright browser

```powershell
python -m playwright install chromium
```

### Step 3 — Run the app

```powershell
python main.py
```

---

## First launch

On the first run (or when your session expires), a **visible Chromium browser window** will open automatically and navigate to `claude.ai/login`. Log in to your Claude.ai account normally. The browser window closes itself once login succeeds, and the app icon appears in your system tray.

Your session cookie is stored in:
```
%APPDATA%\ClaudeUsageMonitor\browser_data\
```
This means you only need to log in once — subsequent launches reuse the saved session.

---

## Usage

| Element | Meaning |
|---|---|
| **Green** icon | Plenty of messages left (< 50% used) |
| **Orange** icon | Getting busy (50–80% used) |
| **Red** icon | Almost out (> 80% used) |
| **Grey** icon | No data or stale (last update > 10 min ago) |

**Left-click** (or click "Show Usage") the tray icon to open the usage dashboard:

- **Plan usage limits** section with two progress bars:
  - **Current session** — rate-limit window usage with "Resets in X hr Y min" countdown
  - **Weekly limits / All models** — billing-period usage with reset day and time
- **↻ Refresh** button — force an immediate scrape
- **✕ Quit** button — exit the app

**Right-click** the icon for a quick context menu:

- Current usage and reset countdown at a glance
- **Refresh Interval** submenu — choose 30s / 1m / 2m / 5m / 10m (persisted across launches)
- **Refresh Now** — immediate refresh
- **Show Usage** — open the popup window
- **Quit**

---

## Project structure

```
windows/
├── main.py                    # Entry point / AppController (port of AppDelegate.swift)
├── requirements.txt           # Python dependencies
├── models.py                  # UsageData dataclass (port of Models/UsageData.swift)
├── services/
│   ├── scraping.py            # Playwright browser service (port of WebScrapingService.swift)
│   ├── notifications.py       # Windows toast notifications (port of NotificationService.swift)
│   └── updates.py             # GitHub Releases update check (port of UpdateService.swift)
└── ui/
    ├── tray.py                # pystray system tray icon + menu (port of AppDelegate status bar)
    └── popup.py               # tkinter popup window (port of ContentView.swift)
```

---

## Settings

Settings are stored in `%APPDATA%\ClaudeUsageMonitor\settings.json`:

```json
{
  "refreshInterval": 120
}
```

`refreshInterval` is in seconds (default: 120). You can also change it from the tray right-click menu.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Login window keeps appearing | Your Claude session expired — log in again when the browser window opens |
| Shows `0/0` or no numbers | Claude.ai's page may have changed; open a GitHub Issue |
| Tray icon not appearing | Ensure `pystray` and `Pillow` are installed (`pip install pystray Pillow`) |
| Browser window doesn't open for login | Run `python -m playwright install chromium` to install the browser |
| `winotify` errors | Notifications require Windows 10+; on older Windows, notifications will be logged to console only |

---

## Running at startup (optional)

To launch the app automatically when Windows starts, create a shortcut to `pythonw main.py` in your Startup folder:

1. Press `Win + R`, type `shell:startup`, press Enter
2. Create a shortcut with the target:
   ```
   pythonw "C:\path\to\windows\main.py"
   ```
   (use `pythonw` instead of `python` to avoid a console window)

---

## License

MIT License — same as the original macOS app.
