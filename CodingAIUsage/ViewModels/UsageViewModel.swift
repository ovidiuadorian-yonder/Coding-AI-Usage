import SwiftUI
import Combine
import ServiceManagement

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var claudeUsage: ServiceUsage?
    @Published var codexUsage: ServiceUsage?
    @Published var errors: [String] = []
    @Published var isRefreshing = false

    @AppStorage("showClaude") var showClaude = true
    @AppStorage("showCodex") var showCodex = true
    @AppStorage("pollingIntervalSeconds") var pollingIntervalSeconds: Double = 300
    @AppStorage("alertThreshold") var alertThreshold: Double = 0.10
    @AppStorage("launchAtLogin") var launchAtLogin = false {
        didSet { updateLaunchAtLogin() }
    }

    private let claudeService = ClaudeUsageService()
    private let codexService = CodexUsageService()
    private let notificationService = NotificationService()
    let scheduler = PollingScheduler()

    // Status checks
    @Published var claudeInstalled = false
    @Published var claudeLoggedIn = false
    @Published var codexInstalled = false
    @Published var codexLoggedIn = false

    init() {
        notificationService.requestPermission()
        // Start polling after a short delay to let prerequisites check complete
        Task { @MainActor in
            await checkPrerequisitesAsync()
            startPolling()
        }
    }

    func startPolling() {
        scheduler.updateBaseInterval(pollingIntervalSeconds)
        scheduler.start { [weak self] in
            await self?.refresh()
        }
    }

    func stopPolling() {
        scheduler.stop()
    }

    func refresh() async {
        isRefreshing = true
        errors.removeAll()

        await checkPrerequisitesAsync()

        async let claudeResult: Void = fetchClaude()
        async let codexResult: Void = fetchCodex()
        _ = await (claudeResult, codexResult)

        isRefreshing = false
    }

    func manualRefresh() {
        scheduler.resetBackoff()
        Task {
            await refresh()
        }
    }

    func updatePollingInterval(_ seconds: Double) {
        pollingIntervalSeconds = seconds
        scheduler.updateBaseInterval(seconds)
    }

    // MARK: - Menu Bar Text

    var menuBarText: AttributedString {
        var parts: [(String, UsageLevel, UsageLevel)] = [] // (text, 5hLevel, wLevel)

        if showClaude, let claude = claudeUsage, claude.error == nil {
            let fh = claude.fiveHourWindow
            let w = claude.weeklyWindow
            parts.append((
                "CC",
                fh?.level ?? .normal,
                w?.level ?? .normal
            ))
        }

        if showCodex, let codex = codexUsage, codex.error == nil, !codex.windows.isEmpty {
            let fh = codex.fiveHourWindow
            let w = codex.weeklyWindow
            parts.append((
                "CX",
                fh?.level ?? .normal,
                w?.level ?? .normal
            ))
        }

        if parts.isEmpty {
            return AttributedString("Coding Usage")
        }

        var result = AttributedString()
        for (i, part) in parts.enumerated() {
            if i > 0 {
                result += AttributedString("  ")
            }

            let service = part.0 == "CC" ? claudeUsage : codexUsage
            let fhPercent = service?.fiveHourWindow?.remainingPercent ?? 0
            let wPercent = service?.weeklyWindow?.remainingPercent ?? 0

            result += AttributedString("\(part.0) %5h ")

            var fhAttr = AttributedString("\(fhPercent)")
            fhAttr.foregroundColor = part.1 == .critical ? .red : .green
            result += fhAttr

            result += AttributedString(" %W ")

            var wAttr = AttributedString("\(wPercent)")
            wAttr.foregroundColor = part.2 == .critical ? .red : .green
            result += wAttr
        }

        return result
    }

    // Plain text for status bar (NSAttributedString doesn't work in MenuBarExtra label)
    var menuBarPlainText: String {
        var parts: [String] = []

        if showClaude, let claude = claudeUsage, claude.error == nil {
            let fh = claude.fiveHourWindow?.remainingPercent ?? 0
            let w = claude.weeklyWindow?.remainingPercent ?? 0
            parts.append("CC %5h \(fh) %W \(w)")
        }

        if showCodex, let codex = codexUsage, codex.error == nil, !codex.windows.isEmpty {
            let fh = codex.fiveHourWindow?.remainingPercent ?? 0
            let w = codex.weeklyWindow?.remainingPercent ?? 0
            parts.append("CX %5h \(fh) %W \(w)")
        }

        if parts.isEmpty {
            return "Coding Usage"
        }

        return parts.joined(separator: "  ")
    }

    var worstLevel: UsageLevel {
        let levels = [claudeUsage?.worstLevel, codexUsage?.worstLevel].compactMap { $0 }
        return levels.max() ?? .normal
    }

    var hasCritical: Bool {
        worstLevel == .critical
    }

    // MARK: - Private

    private func checkPrerequisitesAsync() async {
        let ci = await claudeService.checkInstalled()
        let cxi = await codexService.checkInstalled()
        let cl = KeychainService().isClaudeLoggedIn()
        let cxl = await codexService.isLoggedIn()

        claudeInstalled = ci
        claudeLoggedIn = cl
        codexInstalled = cxi
        codexLoggedIn = cxl

        if showClaude {
            if !ci { errors.append("Claude Code not installed") }
            else if !cl { errors.append("Claude Code: not logged in") }
        }
        if showCodex {
            if !cxi { errors.append("Codex not installed") }
            else if !cxl { errors.append("Codex: not logged in") }
        }
    }

    private func fetchClaude() async {
        guard showClaude else {
            claudeUsage = nil
            return
        }
        guard claudeInstalled, claudeLoggedIn else { return }

        do {
            let usage = try await claudeService.fetchUsage()
            claudeUsage = usage
            scheduler.reportSuccess()
            notificationService.checkAndNotify(service: usage, threshold: alertThreshold)
        } catch let error as UsageError {
            switch error {
            case .rateLimited(let retryAfter):
                scheduler.reportRateLimited(retryAfter: retryAfter)
                let retryText = retryAfter.map { " (retry in \(Int($0))s)" } ?? ""
                errors.append("Claude Code: rate limited\(retryText) - will retry automatically")
            default:
                errors.append(error.localizedDescription)
                claudeUsage = ServiceUsage(
                    id: "claude", displayName: "Claude Code", shortLabel: "CC",
                    windows: [], lastUpdated: Date(), error: error.localizedDescription
                )
            }
        } catch {
            errors.append("Claude Code: \(error.localizedDescription)")
        }
    }

    private func fetchCodex() async {
        guard showCodex else {
            codexUsage = nil
            return
        }
        guard codexInstalled, codexLoggedIn else { return }

        do {
            let usage = try await codexService.fetchUsage()
            codexUsage = usage
            notificationService.checkAndNotify(service: usage, threshold: alertThreshold)
        } catch let error as UsageError {
            switch error {
            case .rateLimited(let retryAfter):
                scheduler.reportRateLimited(retryAfter: retryAfter)
                let retryText = retryAfter.map { " (retry in \(Int($0))s)" } ?? ""
                errors.append("Codex: rate limited\(retryText) - will retry automatically")
            default:
                errors.append(error.localizedDescription)
                codexUsage = ServiceUsage(
                    id: "codex", displayName: "Codex", shortLabel: "CX",
                    windows: [], lastUpdated: Date(), error: error.localizedDescription
                )
            }
        } catch {
            errors.append("Codex: \(error.localizedDescription)")
        }
    }

    private func updateLaunchAtLogin() {
        if launchAtLogin {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}
