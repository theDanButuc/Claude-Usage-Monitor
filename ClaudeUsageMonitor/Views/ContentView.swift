import SwiftUI

struct ContentView: View {
    @EnvironmentObject var service: WebScrapingService

    var body: some View {
        ZStack {
            // Frosted-glass base
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
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
            Image(systemName: "tree.fill")
                .foregroundStyle(iconColor)
                .font(.system(size: 16, weight: .semibold))

            Text("Claude Usage")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            if let data = service.usageData {
                planBadge(data.planType)
            }
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
        VStack(spacing: 20) {
            if service.isLoading && service.usageData == nil {
                loadingView
            } else if let msg = service.errorMessage, service.usageData == nil {
                errorView(msg)
            } else {
                progressSection
                if let data = service.usageData {
                    resetRow(data)
                    statsRow(data)
                }
            }
        }
        .padding(16)
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

    // MARK: - Progress ring

    private var progressSection: some View {
        let data  = service.usageData
        let used  = data?.messagesUsed  ?? 0
        let limit = data?.messagesLimit ?? 0
        let pct   = data?.usagePercentage ?? 0

        return VStack(spacing: 6) {
            CircularProgressView(
                progress:      pct,
                messagesUsed:  used,
                messagesLimit: limit
            )
            .frame(width: 170, height: 170)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if service.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .offset(x: 4, y: -4)
                }
            }

            if service.usageData != nil {
                Text("Billing period usage")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Reset countdown row

    private func resetRow(_ data: UsageData) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            Text("Resets in")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(data.timeUntilReset)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            // Remaining count pill
            Text("\(data.messagesRemaining) left")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Stats cards row

    private func statsRow(_ data: UsageData) -> some View {
        HStack(spacing: 10) {
            statCard(
                icon: "chart.bar.fill",
                label: "Remaining",
                value: data.messagesLimit > 0 ? "\(data.messagesRemaining)" : "—",
                color: .blue
            )
            statCard(
                icon: "bolt.fill",
                label: "Rate limit",
                value: data.rateLimitStatus,
                color: data.rateLimitStatus == "Limited" ? .orange : .green
            )
        }
    }

    private func statCard(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let data = service.usageData {
                Text("Updated \(data.lastUpdatedFormatted)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Not yet updated")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                service.refresh()
            } label: {
                Image(systemName: service.isLoading ? "arrow.clockwise" : "arrow.clockwise")
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

    private var iconColor: Color {
        switch service.usageData?.usagePercentage ?? 0 {
        case 0.8...: return .red
        case 0.5...: return .orange
        default:     return .green
        }
    }
}

