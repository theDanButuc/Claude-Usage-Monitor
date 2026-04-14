import AppKit
import WebKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// LoginWindowController — shows a browser window for Claude.ai OAuth login.
// After successful login it extracts the sessionKey cookie, stores it in
// ClaudeAPIService, then calls onLoginSuccess.
// Does NOT depend on WebScrapingService.
// ─────────────────────────────────────────────────────────────────────────────

final class LoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {

    var onLoginSuccess: (() -> Void)?
    private var webView: WKWebView!

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
    }

    private func setupContent() {
        guard let window else { return }

        // Share the default cookie store so the session persists across app launches
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.translatesAutoresizingMaskIntoConstraints = false

        let banner = NSTextField(labelWithString:
            "Log in to Claude to allow the usage monitor to read your data.")
        banner.font = .systemFont(ofSize: 13)
        banner.textColor = .secondaryLabelColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.alignment = .center

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(banner)
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            webView.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 10),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window.contentView = container
        // Load settings/usage — redirects to /login if not authenticated,
        // goes directly to the page if already logged in.
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }
        // Login is complete once we're past the /login and /oauth screens
        guard !url.contains("/login") && !url.contains("/oauth") && url.contains("claude.ai") else {
            return
        }
        extractSessionKey()
    }

    // MARK: - Session key extraction

    private func extractSessionKey() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            // No domain filter — cookie domain varies (.claude.ai vs claude.ai)
            let key = cookies.first { $0.name == "sessionKey" }?.value
            DispatchQueue.main.async {
                if let key {
                    ClaudeAPIService.shared.sessionKey = key
                    self.onLoginSuccess?()
                }
                // If no key found yet, do nothing — user may still be on an intermediate page
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Nothing special — AppDelegate handles the nil case
    }
}
