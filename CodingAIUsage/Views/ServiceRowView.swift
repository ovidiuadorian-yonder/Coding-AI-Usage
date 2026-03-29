import SwiftUI

struct ServiceRowView: View {
    let usage: ServiceUsage
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text(usage.displayName)
                    .font(.headline)
            }

            if let error = usage.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                ForEach(usage.windows) { window in
                    WindowRow(window: window)
                }
            }

            ForEach(usage.footerLines, id: \.self) { line in
                Text(line)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

        }
        .padding(.vertical, 4)
    }
}

struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.name)
                    .font(.subheadline)
                Spacer()
                Text("\(window.remainingPercent)% remaining")
                    .font(.subheadline)
                    .foregroundColor(window.level == .critical ? .red : .green)
            }

            ProgressView(value: window.remaining)
                .tint(window.level.color)

            if let resetTime = window.resetTime {
                Text("Resets \(resetTime, style: .relative)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
