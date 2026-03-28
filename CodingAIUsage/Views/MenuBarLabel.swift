import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        Image(nsImage: renderMenuBarImage())
    }

    private func renderMenuBarImage() -> NSImage {
        let parts = buildParts()

        if parts.isEmpty {
            return renderAttributedString(NSAttributedString(
                string: "Coding Usage",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
            ))
        }

        let result = NSMutableAttributedString()
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]

        for (i, part) in parts.enumerated() {
            if i > 0 {
                result.append(NSAttributedString(string: "  ", attributes: normalAttrs))
            }

            // Service label (CC or CX)
            result.append(NSAttributedString(string: "\(part.label) ", attributes: normalAttrs))

            // 5h value - colored independently
            result.append(NSAttributedString(string: "%5h ", attributes: normalAttrs))
            result.append(NSAttributedString(
                string: "\(part.fiveHourPercent)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: colorForLevel(part.fiveHourLevel)
                ]
            ))

            // Weekly value - colored independently
            result.append(NSAttributedString(string: " %W ", attributes: normalAttrs))
            result.append(NSAttributedString(
                string: "\(part.weeklyPercent)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: colorForLevel(part.weeklyLevel)
                ]
            ))
        }

        return renderAttributedString(result)
    }

    private struct MenuBarPart {
        let label: String
        let fiveHourPercent: Int
        let fiveHourLevel: UsageLevel
        let weeklyPercent: Int
        let weeklyLevel: UsageLevel
    }

    private func buildParts() -> [MenuBarPart] {
        var parts: [MenuBarPart] = []

        if viewModel.showClaude, let claude = viewModel.claudeUsage, claude.error == nil {
            parts.append(MenuBarPart(
                label: "CC",
                fiveHourPercent: claude.fiveHourWindow?.remainingPercent ?? 0,
                fiveHourLevel: claude.fiveHourWindow?.level ?? .normal,
                weeklyPercent: claude.weeklyWindow?.remainingPercent ?? 0,
                weeklyLevel: claude.weeklyWindow?.level ?? .normal
            ))
        }

        if viewModel.showCodex, let codex = viewModel.codexUsage, codex.error == nil, !codex.windows.isEmpty {
            parts.append(MenuBarPart(
                label: "CX",
                fiveHourPercent: codex.fiveHourWindow?.remainingPercent ?? 0,
                fiveHourLevel: codex.fiveHourWindow?.level ?? .normal,
                weeklyPercent: codex.weeklyWindow?.remainingPercent ?? 0,
                weeklyLevel: codex.weeklyWindow?.level ?? .normal
            ))
        }

        return parts
    }

    private func colorForLevel(_ level: UsageLevel) -> NSColor {
        switch level {
        case .critical: return NSColor.systemRed
        case .warning: return NSColor.systemYellow
        case .normal: return NSColor.systemGreen
        }
    }

    private func renderAttributedString(_ attrString: NSAttributedString) -> NSImage {
        let size = attrString.size()
        let imageSize = NSSize(width: ceil(size.width) + 2, height: 18)
        let image = NSImage(size: imageSize)

        image.lockFocus()
        attrString.draw(at: NSPoint(x: 1, y: (18 - ceil(size.height)) / 2))
        image.unlockFocus()

        image.isTemplate = false // Important: allows colors to show
        return image
    }
}
