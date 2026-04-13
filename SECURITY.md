# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| ≥ 1.4.x | ✅ Yes     |
| < 1.4   | ❌ No      |

## How It Works (Transparency)

ClaudeUsageMonitor uses a hidden `WKWebView` that loads `claude.ai/settings/usage` using your existing browser session — the same WebKit cookie store used by Safari. It does **not**:

- Store your Claude credentials
- Send your data to any third-party server
- Make requests to any server other than `claude.ai`
- Require an API key or access token

All data stays on your machine. The app is open source — you can audit every line at [github.com/theDanButuc/Claude-Usage-Monitor](https://github.com/theDanButuc/Claude-Usage-Monitor).

## Reporting a Vulnerability

If you discover a security vulnerability, please **do not open a public GitHub Issue**.

Instead, report it privately:

1. Go to the [Security tab](https://github.com/theDanButuc/Claude-Usage-Monitor/security/advisories/new) on GitHub
2. Click **"Report a vulnerability"**
3. Describe the issue with as much detail as possible

You can expect a response within **48 hours**. If the vulnerability is confirmed, a fix will be released as soon as possible and you will be credited in the release notes (unless you prefer to remain anonymous).
