# ClaudeUsageMonitor — Developer Log

> Single source of truth for architecture, roadmap, data model, and development history.
> Keep this updated as the project evolves.

---

## Architecture

### Data pipeline

1. A hidden `WKWebView` loads `claude.ai/settings/usage` using the default WebKit cookie store (same session as Safari)
2. A **JS fetch/XHR interceptor** injected at `documentStart` captures all API responses with usage/quota data → forwarded to Swift via `WKScriptMessageHandler`
3. **DOM extraction** runs 5s after page load as fallback (reads `aria-progressbar` values and text patterns)
4. Swift parses both sources and merges into `UsageData`

### Key files

| File | Role |
|------|------|
| `AppDelegate.swift` | Menu bar icon, popover, refresh timer, right-click menu, usageHistory |
| `Models/UsageData.swift` | Data model + all computed properties |
| `Services/WebScrapingService.swift` | WKWebView + JS interceptor + DOM extraction |
| `Services/NotificationService.swift` | Usage threshold + session reset notifications |
| `Services/UpdateService.swift` | GitHub Releases update check |
| `Views/ContentView.swift` | Popover UI (two-bar dashboard + smart tip banner) |
| `Views/CircularProgressView.swift` | Kept in project but currently unused |

### Data model (UsageData.swift — v1.4.1)

**Stored:**
```swift
var planType:        String
var messagesUsed:    Int        // billing-period total (from DOM)
var messagesLimit:   Int        // billing-period limit  (from DOM)
var sessionUsed:     Int        // current rate-limit window (from API)
var sessionLimit:    Int        // current rate-limit window (from API)
var resetDate:       Date?      // session window reset (from API — future dates only)
var weeklyResetDate: Date?      // billing period reset (from DOM absolute date)
var weeklyResetText: String     // e.g. "Fri 10:00 AM" (from DOM, raw string)
var rateLimitStatus: String
var lastUpdated:     Date
var usageHistory:    [(date: Date, pct: Double)]  // rolling 10-point window (set by AppDelegate)
```

**Computed:**
```swift
var sessionPercentage: Double   // sessionUsed / sessionLimit
var weeklyPercentage: Double    // messagesUsed / messagesLimit
var usagePercentage: Double     // primaryUsed / primaryLimit (fallback: session → billing)
var burnRatePerMinute: Double?  // requires ≥2 points, ≥5 min apart, pct increasing
var estimatedMinutesRemaining: Double?  // capped at resetDate
var burnRateLabel: String?      // "~45min left" or "~2h 3m left"
var menuBarLabel: String        // burnRateLabel ?? "x%" | "y%"
var sessionResetLabel: String?  // "Resets in 3 hr 9 min" (nil if past/unknown)
var weeklyResetLabel: String?   // "Resets Fri 10:00 AM"
var smartTip: String?           // contextual tip at 75/80/90/95%
var isStale: Bool               // lastUpdated > 10 min ago
```

**Naming note:** Use `sessionPercentage` / `weeklyPercentage` — NOT `sessionUsedPercent` / `weeklyUsedPercent` (those were wrong names in older docs).

### usageHistory — important design note

`usageHistory` is maintained in **AppDelegate** (not in WebScrapingService). On each `$usageData` sink event:
1. Detect session reset: if `sessionPercentage` dropped > 0.01 → `usageHistory.removeAll()`
2. Append `(Date(), sessionPercentage)`
3. Trim to last 10 entries
4. Create a local `enriched` copy with history attached
5. Pass `enriched` to `updateIcon()` and `notifications.checkAndNotify()` — **never write back to `service.usageData`** (causes Combine sink loop)

### Build system

```bash
bash scripts/build.sh --version X.Y.Z   # produces dist/ClaudeUsageMonitor-vX.Y.Z.dmg
```
No Xcode.app needed — only Xcode Command Line Tools.

**CI/CD:** Push a git tag `vX.Y.Z` → GitHub Actions (`release.yml`) builds universal DMG + publishes GitHub Release automatically.

---

## Version History

### v1.4.1 (2026-04-01) — current
- **Fix:** Moved `usageHistory` to `AppDelegate` to prevent Combine sink loop (`service.$usageData` sink was writing back to `service.usageData`, causing recursive publisher updates)

### v1.4.0 (2026-03-31)
- **Feature:** Burn rate in menu bar — `~45min left | 42%` based on rolling usage history; falls back to `%` when idle or insufficient data
- **Feature:** Smart tip banner in popover — dismissable, re-shows at each new threshold (75→80→90→95%)
- **Feature:** Notifications extended to 75/80/90/95/100% with contextual messages
- **Fix:** `NotificationService` now uses `sessionPercentage` instead of `usagePercentage`

### v1.3.1 (2026-03-31)
- **Fix:** Reset countdown showing "Soon" instead of actual time (issue #1)
  - `applyAPIResult`: only store `resetDate` if it's in the future
  - `refresh()`: clear `resetDate`/`weeklyResetDate` on each reload
  - `sessionResetLabel`: return `nil` instead of "Resets soon" when date is past

### v1.3.0 (2026-03-31)
- Replace circular progress ring with two horizontal bar charts
- Menu bar label: `x/100` → `x% | y%` (session | weekly)
- Add `weeklyResetDate` + `weeklyResetText` — DOM now captures "Resets Fri 10:00 AM" separately from session countdown
- Remove PRO/MAX plan badge from popover header
- Remove rate limit card from popover
- Popover height: 440 → 380px

### v1.2.0 (2026-03-24)
- Live reset countdown sourced from Claude API (`reset_at` field)
- Recursive `findResetDate()` searches nested JSON
- DOM fallback delay increased to 5s

### v1.1.0 (2026-03-23)
- `UpdateService`: checks GitHub Releases API on launch, shows update banner
- Homebrew tap cask formula
- CI: `update-homebrew-tap.yml` auto-updates cask after release

### v1.0.0 (2026-03-23)
- Initial release
- Menu bar icon + popover with circular progress ring
- WKWebView scraping + JS fetch/XHR interceptor
- Configurable refresh interval (30s/1m/2m/5m/10m)
- Native notifications at 80/90/100%
- Stale data indicator (grey icon + ⚠)
- Right-click context menu

---

## Roadmap

### High priority

**#1 — Resilient parsing**
- Problem: if Claude.ai updates their DOM/API, app shows `0/0` silently
- Plan: cache last successful `UsageData` in `UserDefaults` (Codable); if 3 consecutive scrapes return 0/0, show cached data with "stale" banner and prompt user to open a GitHub Issue
- Files: `WebScrapingService.swift`, `UsageData.swift` (add `Codable`), `ContentView.swift`

### Medium priority

**#4 — Usage history mini chart**
- Persist snapshots (timestamp + sessionPct) to UserDefaults (last 50)
- Render SwiftUI `Charts` line chart in popover
- Files: new `HistoryStore.swift`, `ContentView.swift`

**#5 — Multi-account support** *(v2.0 milestone)*
- Separate `WKWebsiteDataStore` per account
- Account switcher in popover/right-click menu
- Files: new `AccountManager.swift`, `WebScrapingService.swift`, `LoginWindowController.swift`

### Low priority

**#8 — Apple Notarization**
- Requires $99/year Apple Developer Program
- Eliminates "right-click → Open" friction on first launch
- Single biggest adoption unblock

**#9 — Official Homebrew Cask**
- After notarization, submit PR to `homebrew/homebrew-cask`
- Enables `brew install --cask claude-usage-monitor`

---

## Testing checklist (v1.4.x)

- [ ] Burn rate shows after ≥2 data points with ≥5 min gap
- [ ] Menu bar reverts to `%` display when idle (burn rate = 0)
- [ ] Estimated time never exceeds actual `resetDate`
- [ ] Notifications fire exactly once per threshold per session
- [ ] Notifications do NOT re-fire after session reset
- [ ] Tip banner appears at 75%+ and is dismissable
- [ ] Tip banner re-shows automatically when crossing next threshold
- [ ] `usageHistory` clears correctly on session reset detection
- [ ] Weekly reset label shows correct day/time from claude.ai (not hardcoded)
- [ ] Stale indicator appears after 10 min without update
