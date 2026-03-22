import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var loginWindowController: LoginWindowController?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let service = WebScrapingService.shared

    // MARK: - Application lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        observeService()
        startApp()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(handleStatusItemClick)
        button.target  = self
        button.toolTip = "Claude Usage Monitor"
        updateIcon(data: nil)
    }

    private func updateIcon(data: UsageData?) {
        guard let button = statusItem.button else { return }

        let pct = data?.usagePercentage ?? 0
        let color: NSColor = {
            switch pct {
            case 0.8...:  return .systemRed
            case 0.5...:  return .systemYellow
            default:      return .systemGreen
            }
        }()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))

        if let img = NSImage(systemSymbolName: "tree.fill",
                             accessibilityDescription: "Claude Usage")?
            .withSymbolConfiguration(symbolConfig) {
            button.image = img
        }

        // Show "used/limit" text next to the icon
        if let label = data?.menuBarLabel, !label.isEmpty {
            button.title = " \(label)"
        } else {
            button.title = ""
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        let rootView = ContentView().environmentObject(service)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true

        popover = NSPopover()
        popover.contentSize       = NSSize(width: 320, height: 440)
        popover.behavior          = .transient
        popover.animates          = true
        popover.contentViewController = hostingController
    }

    @objc private func handleStatusItemClick() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // Refresh on every open, unless a refresh is already in flight
            // or data is less than 30 seconds old.
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
                self?.updateIcon(data: data)
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

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.service.refresh()
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
