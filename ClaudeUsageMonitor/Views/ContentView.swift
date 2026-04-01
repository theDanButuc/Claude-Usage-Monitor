import SwiftUI

struct ContentView: View {
    @EnvironmentObject var service: WebScrapingService

    @AppStorage("availableUpdate") private var availableUpdate: String = ""
    @State private var tipDismissed = false
    @State private var lastTipThreshold = 0

    private var refreshIntervalLabel: String {
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        let secs = interval > 0 ? interval : 120
        if secs < 60 { return "\(Int(secs))s" }
        let mins = Int(secs / 60)
        return "\(mins)m"
    }

    var body: some View {
        ZStack {
            // Frosted-glass base
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if !availableUpdate.isEmpty {
                    updateBanner
                }
                Divider().opacity(0.4)
                scrollableContent
                Divider().opacity(0.4)
                footer
            }
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: {
                let img = NSImage(named: NSImage.applicationIconName) ?? NSImage()
                let copy = img.copy() as! NSImage
                copy.size = NSSize(width: 20, height: 20)
                return copy
            }())

            Text("Claude Usage")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func planBadge(_ plan: String) -> some View {
        Text(plan.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(planColor(plan))
            .clipShape(Capsule())
    }

    private func planColor(_ plan: String) -> Color {
        switch plan.lowercased() {
        case "pro":  return .green
        case "max":  return .purple
        case "team": return .blue
        default:     return .gray
        }
    }

    // MARK: - Main scrollable area

    private var scrollableContent: some View {
        VStack(spacing: 16) {
            if service.isLoading && service.usageData == nil {
                loadingView
            } else if let msg = service.errorMessage, service.usageData == nil {
                errorView(msg)
            } else {
                if let data = service.usageData, data.isStale {
                    staleBanner
                }
                smartTipBanner
                barsSection
            }
        }
        .padding(16)
    }

    // MARK: - Update banner

    private var updateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 13))
            Text("v\(availableUpdate) available")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            Button("View Release") {
                NSWorkspace.shared.open(UpdateService.shared.releaseURL)
                availableUpdate = ""
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.blue)
            .buttonStyle(.plain)

            Button {
                availableUpdate = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.blue.opacity(0.08))
    }

    // MARK: - Stale data banner

    private var staleBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text("Data may be outdated")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Spacer()
            Button("Refresh") { service.refresh() }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Loading / error states

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.3)
            Text("Loading usage data…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { service.refresh() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Smart tip banner

    private var smartTipBanner: some View {
        Group {
            if let tip = service.usageData?.smartTip, !tipDismissed {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    Text(tip)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        tipDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: thresholdLevel(service.usageData?.sessionPercentage ?? 0)) { newLevel in
                    if newLevel > lastTipThreshold {
                        tipDismissed = false
                        lastTipThreshold = newLevel
                    }
                }
            }
        }
    }

    /// Maps session percentage to a threshold level (0=none,1=75%,2=80%,3=90%,4=95%)
    private func thresholdLevel(_ pct: Double) -> Int {
        switch pct * 100 {
        case 95...: return 4
        case 90...: return 3
        case 80...: return 2
        case 75...: return 1
        default:    return 0
        }
    }

    // MARK: - Bars section

    private var barsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Plan usage limits")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 14)

            if let data = service.usageData {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    VStack(spacing: 0) {
                        // Current session bar
                        usageBarRow(
                            title: "Current session",
                            resetLabel: data.sessionResetLabel,
                            used: data.sessionUsed,
                            limit: data.sessionLimit,
                            progress: data.sessionPercentage
                        )

                        Divider()
                            .opacity(0.3)
                            .padding(.vertical, 14)

                        // Weekly limits section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Weekly limits")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            usageBarRow(
                                title: "All models",
                                resetLabel: data.weeklyResetLabel,
                                used: data.messagesUsed,
                                limit: data.messagesLimit,
                                progress: data.weeklyPercentage
                            )
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            service.isLoading
                ? AnyView(
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                  )
                : AnyView(EmptyView())
        )
    }

    private func usageBarRow(
        title: String,
        resetLabel: String?,
        used: Int,
        limit: Int,
        progress: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let label = resetLabel {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if limit == 0 {
                        Text("No data")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if limit > 0 {
                    Text("\(Int(progress * 100))% used")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            if limit > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor(for: progress))
                            .frame(width: max(8, geo.size.width * CGFloat(progress)), height: 8)
                            .animation(.spring(response: 0.7, dampingFraction: 0.8), value: progress)
                    }
                }
                .frame(height: 8)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 8)
            }
        }
    }

    private func barColor(for progress: Double) -> Color {
        switch progress {
        case 0.8...: return .red
        case 0.5...: return .orange
        default:     return .green
        }
    }

    // MARK: - Rate limit card

    private func rateLimitCard(_ data: UsageData) -> some View {
        HStack(spacing: 8) {
            Image(systemName: data.rateLimitStatus == "Limited" ? "bolt.slash.fill" : "bolt.fill")
                .foregroundStyle(data.rateLimitStatus == "Limited" ? .orange : .green)
                .font(.system(size: 13))
            Text("Rate limit")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(data.rateLimitStatus)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(data.rateLimitStatus == "Limited" ? .orange : .primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let data = service.usageData {
                    Text("Updated \(data.lastUpdatedFormatted)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not yet updated")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text("Refreshes every \(refreshIntervalLabel)  ·  Right-click icon to change")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.primary.opacity(0.25))
            }

            Spacer()

            Button {
                service.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(service.isLoading ? .degrees(360) : .zero)
                    .animation(
                        service.isLoading
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: service.isLoading
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
            .disabled(service.isLoading)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit ClaudeUsageMonitor")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

}
