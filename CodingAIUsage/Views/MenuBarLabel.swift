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

        // Build segments: each segment is either a badge (label) or plain text
        var segments: [(text: NSAttributedString, badge: NSColor?)] = []
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]

        for (i, part) in parts.enumerated() {
            if i > 0 {
                segments.append((NSAttributedString(string: "  ", attributes: normalAttrs), nil))
            }

            // Badge for the service label (CC or CX)
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            segments.append((NSAttributedString(string: part.label, attributes: badgeAttrs), part.badgeColor))

            // Usage values
            segments.append((NSAttributedString(string: " 5h% ", attributes: normalAttrs), nil))
            segments.append((NSAttributedString(
                string: "\(part.fiveHourPercent)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: colorForLevel(part.fiveHourLevel)
                ]
            ), nil))
            segments.append((NSAttributedString(string: " | w% ", attributes: normalAttrs), nil))
            segments.append((NSAttributedString(
                string: "\(part.weeklyPercent)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: colorForLevel(part.weeklyLevel)
                ]
            ), nil))
        }

        return renderSegments(segments)
    }

    private struct MenuBarPart {
        let label: String
        let badgeColor: NSColor
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
                badgeColor: NSColor(red: 0.45, green: 0.27, blue: 0.80, alpha: 1.0), // Anthropic purple
                fiveHourPercent: claude.fiveHourWindow?.remainingPercent ?? 0,
                fiveHourLevel: claude.fiveHourWindow?.level ?? .normal,
                weeklyPercent: claude.weeklyWindow?.remainingPercent ?? 0,
                weeklyLevel: claude.weeklyWindow?.level ?? .normal
            ))
        }

        if viewModel.showCodex, let codex = viewModel.codexUsage, codex.error == nil, !codex.windows.isEmpty {
            parts.append(MenuBarPart(
                label: "CX",
                badgeColor: NSColor(red: 0.07, green: 0.60, blue: 0.52, alpha: 1.0), // OpenAI teal
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

    private func renderSegments(_ segments: [(text: NSAttributedString, badge: NSColor?)]) -> NSImage {
        let badgePadH: CGFloat = 4 // horizontal padding inside badge
        let badgePadV: CGFloat = 1 // vertical padding inside badge
        let badgeRadius: CGFloat = 3

        // Calculate total width
        var totalWidth: CGFloat = 2 // initial margin
        var segmentPositions: [(x: CGFloat, width: CGFloat)] = []

        for seg in segments {
            let size = seg.text.size()
            let w = seg.badge != nil ? ceil(size.width) + badgePadH * 2 : ceil(size.width)
            segmentPositions.append((x: totalWidth, width: w))
            totalWidth += w
        }
        totalWidth += 2 // trailing margin

        let imageSize = NSSize(width: totalWidth, height: 18)
        let image = NSImage(size: imageSize)

        image.lockFocus()

        for (i, seg) in segments.enumerated() {
            let pos = segmentPositions[i]
            let textSize = seg.text.size()

            if let badgeColor = seg.badge {
                // Draw rounded-rect badge background
                let badgeRect = NSRect(
                    x: pos.x,
                    y: (18 - ceil(textSize.height) - badgePadV * 2) / 2,
                    width: pos.width,
                    height: ceil(textSize.height) + badgePadV * 2
                )
                let path = NSBezierPath(roundedRect: badgeRect, xRadius: badgeRadius, yRadius: badgeRadius)
                badgeColor.setFill()
                path.fill()

                // Draw text centered in badge
                seg.text.draw(at: NSPoint(
                    x: pos.x + badgePadH,
                    y: (18 - ceil(textSize.height)) / 2
                ))
            } else {
                // Draw plain text
                seg.text.draw(at: NSPoint(
                    x: pos.x,
                    y: (18 - ceil(textSize.height)) / 2
                ))
            }
        }

        image.unlockFocus()

        image.isTemplate = false
        return image
    }
}
