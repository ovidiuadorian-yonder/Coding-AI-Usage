import SwiftUI
import Combine
import ServiceManagement

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var claudeUsage: ServiceUsage?
    @Published var codexUsage: ServiceUsage?
    @Published var windsurfUsage: ServiceUsage?
    @Published var errors: [String] = []
    @Published var isRefreshing = false

    @AppStorage("showClaude") var showClaude = true
    @AppStorage("showCodex") var showCodex = true
    @AppStorage("showWindsurf") var showWindsurf = true
    @AppStorage("pollingIntervalSeconds") var pollingIntervalSeconds: Double = 300
    @AppStorage("alertThreshold") var alertThreshold: Double = 0.10
    @AppStorage("launchAtLogin") var launchAtLogin = false {
        didSet { updateLaunchAtLogin() }
    }

    private let claudeService = ClaudeUsageService()
    private let codexService = CodexUsageService()
    private let windsurfService = WindsurfUsageService()
    private let notificationService = NotificationService()
    let scheduler = PollingScheduler()

    // Status checks (cached - only re-checked on manual refresh)
    @Published var claudeInstalled = false
    @Published var claudeLoggedIn = false
    @Published var codexInstalled = false
    @Published var codexLoggedIn = false
    @Published var windsurfInstalled = false
    @Published var windsurfLoggedIn = false
    private var prerequisitesChecked = false

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

    func refresh(forceLiveWindsurf: Bool = false) async {
        isRefreshing = true
        errors.removeAll()

        if !prerequisitesChecked {
            await checkPrerequisitesAsync()
            prerequisitesChecked = true
        }

        async let claudeResult: Void = fetchClaude()
        async let codexResult: Void = fetchCodex()
        async let windsurfResult: Void = fetchWindsurf(preferLiveRefresh: forceLiveWindsurf)
        _ = await (claudeResult, codexResult, windsurfResult)

        isRefreshing = false
    }

    func manualRefresh() {
        scheduler.resetBackoff()
        prerequisitesChecked = false // Re-check on manual refresh
        Task {
            await refresh(forceLiveWindsurf: true)
        }
    }

    func updatePollingInterval(_ seconds: Double) {
        pollingIntervalSeconds = seconds
        scheduler.updateBaseInterval(seconds)
    }

    // MARK: - Menu Bar Text

    var menuBarPlainText: String {
        var parts: [String] = []

        if showClaude, let claude = claudeUsage, claude.error == nil {
            let fh = claude.fiveHourWindow?.remainingPercent ?? 0
            let w = claude.weeklyWindow?.remainingPercent ?? 0
            parts.append("CC 5h% \(fh) | w% \(w)")
        }

        if showCodex, let codex = codexUsage, codex.error == nil, !codex.windows.isEmpty {
            let primary = codex.primaryWindow?.remainingPercent ?? 0
            let secondary = codex.secondaryWindow?.remainingPercent ?? 0
            parts.append("CX 5h% \(primary) | w% \(secondary)")
        }

        if showWindsurf, let windsurf = windsurfUsage, windsurf.error == nil,
           let daily = windsurf.primaryWindow, let weekly = windsurf.secondaryWindow {
            parts.append("W \(daily.compactLabel)% \(daily.remainingPercent) | \(weekly.compactLabel)% \(weekly.remainingPercent)")
        }

        if parts.isEmpty {
            return "Coding Usage"
        }

        return parts.joined(separator: "  ")
    }

    var lastUpdated: Date? {
        [claudeUsage?.lastUpdated, codexUsage?.lastUpdated, windsurfUsage?.lastUpdated]
            .compactMap { $0 }
            .max()
    }

    var pollingIntervalLabel: String {
        switch pollingIntervalSeconds {
        case ...180: return "3 min"
        case ...300: return "5 min"
        case ...600: return "10 min"
        case ...1800: return "30 min"
        default: return "1 hr"
        }
    }

    var worstLevel: UsageLevel {
        let levels = [claudeUsage?.worstLevel, codexUsage?.worstLevel, windsurfUsage?.worstLevel].compactMap { $0 }
        return levels.max() ?? .normal
    }

    var hasCritical: Bool {
        worstLevel == .critical
    }

    var enabledServicesSummary: String {
        let services = [
            (showClaude, "Claude Code"),
            (showCodex, "Codex"),
            (showWindsurf, "Windsurf")
        ]
            .filter(\.0)
            .map(\.1)

        if services.isEmpty {
            return "Enabled: None"
        }

        return "Enabled: " + services.joined(separator: ", ")
    }

    var globalErrors: [String] {
        Self.filteredGlobalErrors(
            allErrors: errors,
            services: [claudeUsage, codexUsage, windsurfUsage].compactMap { $0 }
        )
    }

    // MARK: - Private

    nonisolated static func filteredGlobalErrors(allErrors: [String], services: [ServiceUsage]) -> [String] {
        let serviceErrors = Set(services.compactMap(\.error))
        return allErrors.filter { !serviceErrors.contains($0) }
    }

    nonisolated static func windsurfFailureUsage(message: String, previous: ServiceUsage?) -> ServiceUsage {
        ServiceUsage(
            id: previous?.id ?? "windsurf",
            displayName: previous?.displayName ?? "Windsurf",
            shortLabel: previous?.shortLabel ?? "W",
            windows: [],
            lastUpdated: Date(),
            error: message,
            footerLines: []
        )
    }

    private func checkPrerequisitesAsync() async {
        let ci = await claudeService.checkInstalled()
        let cxi = await codexService.checkInstalled()
        let cl = KeychainService().isClaudeLoggedIn()
        let cxl = await codexService.isLoggedIn()
        let wi = await windsurfService.checkInstalled()
        let wl = await windsurfService.isLoggedIn()

        claudeInstalled = ci
        claudeLoggedIn = cl
        codexInstalled = cxi
        codexLoggedIn = cxl
        windsurfInstalled = wi
        windsurfLoggedIn = wl

        if showClaude {
            if !ci { errors.append("Claude Code not installed") }
            else if !cl { errors.append("Claude Code: not logged in") }
        }
        if showCodex {
            if !cxi { errors.append("Codex not installed") }
            else if !cxl { errors.append("Codex: not logged in") }
        }
        if showWindsurf {
            if !wi { errors.append("Windsurf not installed") }
            else if !wl { errors.append("Windsurf: not logged in") }
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
        } catch is DecodingError {
            errors.append("Claude Code: unexpected API response format")
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
        } catch is DecodingError {
            errors.append("Codex: unexpected API response format")
        } catch {
            errors.append("Codex: \(error.localizedDescription)")
        }
    }

    private func fetchWindsurf(preferLiveRefresh: Bool = false) async {
        guard showWindsurf else {
            windsurfUsage = nil
            return
        }
        guard windsurfInstalled, windsurfLoggedIn else { return }

        do {
            let usage = try await windsurfService.fetchUsage(preferLiveRefresh: preferLiveRefresh)
            windsurfUsage = usage
            if let error = usage.error {
                errors.append(error)
            } else {
                notificationService.checkAndNotify(service: usage, threshold: alertThreshold)
            }
        } catch let error as UsageError {
            errors.append(error.localizedDescription)
            windsurfUsage = Self.windsurfFailureUsage(
                message: error.localizedDescription,
                previous: windsurfUsage
            )
        } catch is DecodingError {
            let message = "Windsurf: unexpected local state format"
            errors.append(message)
            windsurfUsage = Self.windsurfFailureUsage(message: message, previous: windsurfUsage)
        } catch {
            let message = "Windsurf: \(error.localizedDescription)"
            errors.append(message)
            windsurfUsage = Self.windsurfFailureUsage(message: message, previous: windsurfUsage)
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
