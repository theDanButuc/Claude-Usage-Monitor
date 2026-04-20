import AppKit
import SwiftUI
import Combine
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var loginWindowController: LoginWindowController?
    private var refreshTimer: Timer?
    private var updateCheckTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let service       = ClaudeAPIService.shared
    private let notifications = NotificationService.shared
    private let updater       = UpdateService.shared

    private var usageHistory: [(date: Date, pct: Double)] = []

    // MARK: - Refresh interval (persisted in UserDefaults)

    private var refreshInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: "refreshInterval")
            return stored > 0 ? stored : 120
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "refreshInterval")
            restartTimer()
        }
    }

    // MARK: - Application lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        notifications.requestPermission()
        setupStatusItem()
        setupPopover()
        observeService()
        startApp()
        scheduleUpdateChecks()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon(data: nil)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func updateIcon(data: UsageData?) {
        guard let button = statusItem.button else { return }

        let isStale = data?.isStale ?? false

        if let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: 16, height: 16)
            button.image = img
        }

        if let label = data?.menuBarLabel, !label.isEmpty {
            button.title = isStale ? " ⚠ \(label)" : " \(label)"
        } else {
            button.title = ""
        }

        if let data = data {
            let staleNote = isStale ? " · stale" : ""
            button.toolTip = "Claude Usage Monitor · Updated \(data.lastUpdatedFormatted)\(staleNote)"
        } else {
            button.toolTip = "Claude Usage Monitor"
        }
    }

    // MARK: - Right-click context menu

    private func showContextMenu() {
        guard let button = statusItem.button else { return }

        let menu = NSMenu()

        // Current usage info
        if let data = service.usageData {
            let pctStr = "\(Int(data.usagePercentage * 100))%"
            let usageItem = NSMenuItem(
                title: "\(data.primaryUsed)/\(data.primaryLimit)  (\(pctStr))",
                action: nil,
                keyEquivalent: ""
            )
            usageItem.isEnabled = false
            menu.addItem(usageItem)

            if data.resetDate != nil {
                let resetItem = NSMenuItem(
                    title: "Resets in \(data.timeUntilReset)",
                    action: nil,
                    keyEquivalent: ""
                )
                resetItem.isEnabled = false
                menu.addItem(resetItem)
            }

            if data.isStale {
                let staleItem = NSMenuItem(title: "⚠  Data may be stale", action: nil, keyEquivalent: "")
                staleItem.isEnabled = false
                menu.addItem(staleItem)
            }
        } else {
            let noDataItem = NSMenuItem(title: "No data yet", action: nil, keyEquivalent: "")
            noDataItem.isEnabled = false
            menu.addItem(noDataItem)
        }

        menu.addItem(.separator())

        // Refresh interval submenu
        let intervalItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        let intervalMenu  = NSMenu()
        let options: [(String, TimeInterval)] = [
            ("30 seconds", 30),
            ("1 minute",   60),
            ("2 minutes",  120),
            ("5 minutes",  300),
            ("10 minutes", 600),
        ]
        for (label, interval) in options {
            let item = NSMenuItem(title: label, action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = abs(refreshInterval - interval) < 1 ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // Pop up below the status bar button
        let origin = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: button)
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        refreshInterval = interval
    }

    @objc private func refreshNow() {
        service.refresh()
    }

    // MARK: - Popover

    private func setupPopover() {
        let rootView = ContentView()
            .environmentObject(service)
            .environmentObject(updater)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true

        popover = NSPopover()
        popover.contentSize           = NSSize(width: 320, height: 380)
        popover.behavior              = .transient
        popover.animates              = true
        popover.contentViewController = hostingController
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            let age = service.usageData.map { Date().timeIntervalSince($0.lastUpdated) } ?? 999
            if age > 30 { service.refresh() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Combine observers

    private func observeService() {
        service.$usageData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                guard let self else { return }
                guard let data = data else {
                    self.updateIcon(data: nil)
                    return
                }
                // Detect session reset (pct dropped) → clear history
                if data.sessionPercentage < (self.usageHistory.last?.pct ?? 0) - 0.01 {
                    self.usageHistory.removeAll()
                }
                // Append current point, keep last 10
                self.usageHistory.append((date: Date(), pct: data.sessionPercentage))
                if self.usageHistory.count > 10 { self.usageHistory.removeFirst() }

                // Enrich a local copy — never write back to service.usageData
                var enriched = data
                enriched.usageHistory = self.usageHistory
                self.updateIcon(data: enriched)
                self.notifications.checkAndNotify(data: enriched)
            }
            .store(in: &cancellables)

        service.$needsLogin
            .receive(on: DispatchQueue.main)
            .filter { $0 }
            .sink { [weak self] _ in self?.presentLoginWindow() }
            .store(in: &cancellables)
    }

    // MARK: - Startup + refresh timer

    private func startApp() {
        service.initialLoad()
        restartTimer()
    }

    private func restartTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.service.refresh()
        }
    }

    // MARK: - Update check

    private func scheduleUpdateChecks() {
        updater.checkForUpdates()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.updater.checkForUpdates()
        }
    }

    // MARK: - Login window

    private func presentLoginWindow() {
        if loginWindowController == nil {
            let controller = LoginWindowController()
            controller.onLoginSuccess = { [weak self] in
                DispatchQueue.main.async {
                    self?.loginWindowController?.close()
                    self?.loginWindowController = nil
                    self?.service.needsLogin = false
                    self?.service.refresh()
                }
            }
            loginWindowController = controller
        }
        loginWindowController?.showWindow(nil)
        loginWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
