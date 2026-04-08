import AppKit
import WebKit
import SwiftUI

final class LoginWindowController: NSWindowController, NSWindowDelegate {

    var onLoginSuccess: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        window.title = "Sign in to Claude"
        window.center()
        window.setFrameAutosaveName("LoginWindow")
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self

        setupContent()

        // Observe login success from the scraping service
        WebScrapingService.shared.onLoginSuccess = { [weak self] in
            DispatchQueue.main.async {
                self?.onLoginSuccess?()
            }
        }
    }

    private func setupContent() {
        guard let window else { return }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Banner at the top
        let banner = NSTextField(labelWithString: "Log in to Claude to allow the usage monitor to read your data.")
        banner.font = .systemFont(ofSize: 13)
        banner.textColor = .secondaryLabelColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.alignment = .center

        let wv = WebScrapingService.shared.makeLoginWebView()
        wv.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(banner)
        container.addSubview(wv)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            wv.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 10),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window.contentView = container
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // If user closes the window without logging in, do nothing special
    }
}
