import SwiftUI
import AppKit

struct TipRowView: View {
    let tip: UsageData.UsageTip
    @State private var copiedIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: tip.icon)
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
                    .padding(.top, 1)
                Text(tip.message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }

            if !tip.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(tip.actions.enumerated()), id: \.offset) { index, action in
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(action.copyText, forType: .string)
                            copiedIndex = index
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedIndex = nil
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: copiedIndex == index ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9))
                                Text(copiedIndex == index ? "Copied!" : action.label)
                                    .font(.system(size: 10))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 19)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.20), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}
