# Auto-Update Feature — Design Spec
**Date:** 2026-04-20  
**Version target:** v2.3.0  
**Approach:** Variant B — download DMG + open in Finder (no external dependencies)

---

## What we're building

Two improvements to the existing update flow:

1. **Hourly background check** — instead of checking only at launch, a repeating timer checks GitHub every hour while the app is running
2. **In-app download + install** — the banner's "View Release" button becomes "Update Now"; clicking it downloads the DMG and opens it in Finder for the user to drag-install (1 manual step)

---

## Files changed

### `UpdateService.swift`
- Parse and store `assets[0].browser_download_url` from GitHub API response (the DMG download URL)
- Add `downloadUpdate(from:progress:completion:)` — URLSession download task that writes DMG to a temp file, reports progress (0–1), returns local `URL` on success or `Error` on failure

### `AppDelegate.swift`
- After the existing `checkForUpdates()` call in `applicationDidFinishLaunching`, schedule a `Timer` repeating every 3600s that calls `checkForUpdates()` again
- Store the timer reference to avoid deallocation

### `ContentView.swift`
- Replace `@AppStorage("availableUpdate")` String with an observed enum state: `.available(version, downloadURL)`, `.downloading(progress: Double)`, `.ready(localDMGURL)`
- Banner renders differently per state:
  - **available** — "v2.x.x available" + `Update Now` button + dismiss ✕
  - **downloading** — "Downloading… X%" + inline progress bar (no dismiss)
  - **ready** — "v2.x.x ready" + `Open & Install` button (calls `NSWorkspace.shared.open(dmgURL)`)

---

## State management

A new `@Published var updateState: UpdateState` on `ClaudeAPIService` (or a lightweight `UpdateManager` object) drives the banner. States:

```
enum UpdateState {
    case none
    case available(version: String, downloadURL: URL)
    case downloading(progress: Double)
    case ready(localURL: URL)
}
```

`ContentView` observes this and renders the correct banner variant.

---

## Error handling

- Download fails → revert to `.available` state, show banner again (user can retry)
- GitHub API unreachable → silently skip (no error shown, next check in 1 hour)
- DMG already downloaded (app relaunched before installing) → skip re-download, go straight to `.ready`

---

## What doesn't change

- Dismiss (✕) behaviour — sets state back to `.none`, persists via `UserDefaults` until next version bump
- The hourly timer fires silently — no UI change if already on latest version
- No Sparkle, no appcast, no external dependencies
