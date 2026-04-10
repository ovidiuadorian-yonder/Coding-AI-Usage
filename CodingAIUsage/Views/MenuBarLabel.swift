import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var viewModel: UsageViewModel

    struct MenuBarServiceState {
        let usage: ServiceUsage?
        let isVisible: Bool
        let badgeColor: NSColor?
    }

    struct MenuBarPart {
        let label: String
        let badgeColor: NSColor
        let primaryLabel: String
        let primaryPercent: Int
        let primaryText: String
        let primaryLevel: UsageLevel
        let secondaryLabel: String
        let secondaryPercent: Int
        let secondaryText: String
        let secondaryLevel: UsageLevel
    }

    var body: some View {
        Label {
            Text(viewModel.menuBarPlainText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
        } icon: {
            Image(systemName: menuBarSymbolName)
                .imageScale(.small)
        }
        .foregroundStyle(Color(nsColor: menuBarForegroundColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.menuBarAccessibilityLabel)
        .help(viewModel.menuBarAccessibilityLabel)
    }

    private var menuBarForegroundColor: NSColor {
        Self.foregroundColor(for: viewModel.worstLevel)
    }

    private var menuBarSymbolName: String {
        switch viewModel.worstLevel {
        case .critical:
            return "exclamationmark.triangle.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .normal:
            return "chart.bar.xaxis"
        }
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
            segments.append((NSAttributedString(string: " \(part.primaryLabel)% ", attributes: normalAttrs), nil))
            segments.append((NSAttributedString(
                string: part.primaryText,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: colorForDisplay(part.primaryText, level: part.primaryLevel)
                ]
            ), nil))
            segments.append((NSAttributedString(string: " | \(part.secondaryLabel)% ", attributes: normalAttrs), nil))
            segments.append((NSAttributedString(
                string: part.secondaryText,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: colorForDisplay(part.secondaryText, level: part.secondaryLevel)
                ]
            ), nil))
        }

        return renderSegments(segments)
    }

    private func buildParts() -> [MenuBarPart] {
        Self.menuBarParts(services: [
            MenuBarServiceState(
                usage: viewModel.claudeUsage,
                isVisible: viewModel.showClaude,
                badgeColor: NSColor(red: 0.45, green: 0.27, blue: 0.80, alpha: 1.0)
            ),
            MenuBarServiceState(
                usage: viewModel.codexUsage,
                isVisible: viewModel.showCodex,
                badgeColor: NSColor(red: 0.07, green: 0.60, blue: 0.52, alpha: 1.0)
            ),
            MenuBarServiceState(
                usage: viewModel.windsurfUsage,
                isVisible: viewModel.showWindsurf,
                badgeColor: NSColor(red: 0.0, green: 0.47, blue: 0.84, alpha: 1.0)
            )
        ])
    }

    static func menuBarParts(services: [MenuBarServiceState]) -> [MenuBarPart] {
        services.compactMap { service in
            guard
                service.isVisible,
                let usage = service.usage,
                shouldDisplayInMenuBar(usage)
            else {
                return nil
            }

            let defaultLabels: (String, String) = usage.shortLabel == "W" ? ("d", "w") : ("5h", "w")
            let primaryWindow = usage.primaryWindow
            let secondaryWindow = usage.secondaryWindow

            return MenuBarPart(
                label: usage.shortLabel,
                badgeColor: service.badgeColor ?? defaultBadgeColor(for: usage.shortLabel),
                primaryLabel: primaryWindow?.compactLabel ?? defaultLabels.0,
                primaryPercent: primaryWindow?.remainingPercent ?? 0,
                primaryText: primaryWindow.map { "\($0.remainingPercent)" } ?? "--",
                primaryLevel: primaryWindow?.level ?? .warning,
                secondaryLabel: secondaryWindow?.compactLabel ?? defaultLabels.1,
                secondaryPercent: secondaryWindow?.remainingPercent ?? 0,
                secondaryText: secondaryWindow.map { "\($0.remainingPercent)" } ?? "--",
                secondaryLevel: secondaryWindow?.level ?? .warning
            )
        }
    }

    private static func shouldDisplayInMenuBar(_ usage: ServiceUsage) -> Bool {
        usage.error == nil || usage.shortLabel == "W"
    }

    private static func defaultBadgeColor(for shortLabel: String) -> NSColor {
        switch shortLabel {
        case "CC":
            return NSColor(red: 0.45, green: 0.27, blue: 0.80, alpha: 1.0)
        case "CX":
            return NSColor(red: 0.07, green: 0.60, blue: 0.52, alpha: 1.0)
        case "W":
            return NSColor(red: 0.0, green: 0.47, blue: 0.84, alpha: 1.0)
        default:
            return .controlAccentColor
        }
    }

    static func foregroundColor(for level: UsageLevel) -> NSColor {
        switch level {
        case .critical:
            return .systemRed
        case .warning:
            return .systemOrange
        case .normal:
            return .labelColor
        }
    }

    private func colorForLevel(_ level: UsageLevel) -> NSColor {
        switch level {
        case .critical: return NSColor.systemRed
        case .warning: return NSColor.systemYellow
        case .normal: return NSColor.systemGreen
        }
    }

    private func colorForDisplay(_ text: String, level: UsageLevel) -> NSColor {
        text == "--" ? NSColor.secondaryLabelColor : colorForLevel(level)
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
