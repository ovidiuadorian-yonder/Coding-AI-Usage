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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.name)
                    .font(.subheadline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(window.remainingPercent)% remaining")
                        .font(.subheadline)
                        .monospacedDigit()
                    Label(window.level.statusText, systemImage: window.level.symbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(window.level.color)
                }
            }

            ProgressView(value: window.remaining)
                .tint(window.level.color)

            if let resetTime = window.resetTime {
                Text("Resets \(resetTime, style: .relative)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.name), \(window.remainingPercent)% remaining, \(window.level.statusText)")
    }
}
