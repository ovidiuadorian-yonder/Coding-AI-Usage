import SwiftUI
import Combine

@MainActor
final class UsageViewModel: ObservableObject {
    enum RefreshResult: Equatable {
        case skipped
        case success
        case failure
        case rateLimited(retryAfter: TimeInterval?)
    }

    @Published var claudeUsage: ServiceUsage?
    @Published var codexUsage: ServiceUsage?
    @Published var windsurfUsage: ServiceUsage?
    @Published var errors: [String] = []
    @Published var isRefreshing = false

    @AppStorage("showClaude") var showClaude = true
    @AppStorage("showCodex") var showCodex = true
    @AppStorage("showWindsurf") var showWindsurf = true
    @AppStorage("notificationsEnabled") var notificationsEnabled = false
    @AppStorage("pollingIntervalSeconds") var pollingIntervalSeconds: Double = 300
    @AppStorage("alertThreshold") var alertThreshold: Double = 0.10
    @AppStorage("launchAtLogin") var launchAtLogin = false

    private let claudeService: any ClaudeUsageServing
    private let codexService: any CodexUsageServing
    private let windsurfService: any WindsurfUsageServing
    private let notificationService: NotificationService
    private let claudeAuthLauncher: ClaudeAuthLauncher
    private let launchAtLoginController: LaunchAtLoginControlling
    private let cacheStore: any UsageCacheStoring
    let scheduler: PollingScheduler
    private var hasUnlockedProtectedAccess = false

    // Status checks (re-checked every 10 min, on wake, on manual refresh, and on auth errors)
    @Published var claudeInstalled = false
    @Published var claudeLoggedIn = false
    @Published var codexInstalled = false
    @Published var codexLoggedIn = false
    @Published var windsurfInstalled = false
    @Published var windsurfLoggedIn = false
    private var lastPrerequisitesCheck: Date?
    private let prerequisitesCheckInterval: TimeInterval = 600 // Re-check every 10 min
    private var wakeObserver: NSObjectProtocol?
    nonisolated private static let maxAutomaticRetryInterval: TimeInterval = 1800

    init(
        claudeService: (any ClaudeUsageServing)? = nil,
        codexService: (any CodexUsageServing)? = nil,
        windsurfService: (any WindsurfUsageServing)? = nil,
        notificationService: NotificationService? = nil,
        claudeAuthLauncher: ClaudeAuthLauncher = ClaudeAuthLauncher(),
        launchAtLoginController: LaunchAtLoginControlling = SystemLaunchAtLoginController(),
        cacheStore: (any UsageCacheStoring)? = nil,
        scheduler: PollingScheduler? = nil,
        autostart: Bool = true
    ) {
        self.claudeService = claudeService ?? ClaudeUsageService()
        self.codexService = codexService ?? CodexUsageService()
        self.windsurfService = windsurfService ?? WindsurfUsageService()
        self.notificationService = notificationService ?? NotificationService()
        self.claudeAuthLauncher = claudeAuthLauncher
        self.launchAtLoginController = launchAtLoginController
        self.cacheStore = cacheStore ?? UserDefaultsUsageCacheStore()
        self.scheduler = scheduler ?? PollingScheduler()
        syncLaunchAtLoginState()
        restoreCachedUsage()

        guard autostart else { return }

        if notificationsEnabled {
            self.notificationService.requestPermission()
        }
        Task { @MainActor in
            startPolling()
        }
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.claudeService.invalidateCredentialCache()
                self.scheduler.resetBackoff()
                self.lastPrerequisitesCheck = nil
                let nextInterval = await self.refresh()
                self.scheduler.reschedule(after: nextInterval)
            }
        }
    }

    deinit {
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
    }

    func startPolling() {
        scheduler.updateBaseInterval(pollingIntervalSeconds)
        scheduler.start { [weak self] in
            guard let self else { return nil }
            return await self.refresh()
        }
    }

    func stopPolling() {
        scheduler.stop()
    }

    func refresh(
        forceLiveWindsurf: Bool = false,
        userInitiated: Bool = false
    ) async -> TimeInterval {
        isRefreshing = true
        errors.removeAll()

        if userInitiated {
            hasUnlockedProtectedAccess = true
        }

        guard hasUnlockedProtectedAccess else {
            isRefreshing = false
            return pollingIntervalSeconds
        }

        let needsPrereqCheck = lastPrerequisitesCheck == nil ||
            Date().timeIntervalSince(lastPrerequisitesCheck!) > prerequisitesCheckInterval
        if needsPrereqCheck {
            await checkPrerequisitesAsync()
            lastPrerequisitesCheck = Date()
        }

        async let claudeResult: RefreshResult = fetchClaude()
        async let codexResult: RefreshResult = fetchCodex()
        async let windsurfResult: RefreshResult = fetchWindsurf(preferLiveRefresh: forceLiveWindsurf)
        let results = await [claudeResult, codexResult, windsurfResult]

        isRefreshing = false
        return Self.nextPollingInterval(baseInterval: pollingIntervalSeconds, results: results)
    }

    func manualRefresh() {
        Task { @MainActor in
            await performManualRefresh(forceLiveWindsurf: false)
        }
    }

    func performManualRefresh(forceLiveWindsurf: Bool) async {
        scheduler.resetBackoff()
        lastPrerequisitesCheck = nil
        let nextInterval = await refresh(
            forceLiveWindsurf: forceLiveWindsurf,
            userInitiated: true
        )
        scheduler.reschedule(after: nextInterval)
    }

    func updatePollingInterval(_ seconds: Double) {
        pollingIntervalSeconds = seconds
        scheduler.updateBaseInterval(seconds)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        guard enabled else { return }
        notificationService.requestPermission()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginController.setEnabled(enabled)
        } catch {
            errors.append("Launch at Login: unable to update login item (\(String(describing: error)))")
        }
        syncLaunchAtLoginState()
    }

    func reauthenticateClaude() {
        Task {
            await claudeService.invalidateCredentialCache()
        }
        do {
            try claudeAuthLauncher.launchReauthentication()
        } catch {
            errors.append("Claude Code: unable to launch re-auth flow (\(error.localizedDescription))")
        }
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

    var menuBarAccessibilityLabel: String {
        let summaries = [
            menuBarSummary(for: claudeUsage, visible: showClaude),
            menuBarSummary(for: codexUsage, visible: showCodex),
            menuBarSummary(for: windsurfUsage, visible: showWindsurf)
        ].compactMap { $0 }

        if summaries.isEmpty {
            return "Coding AI usage, no enabled services with available status"
        }

        return "Coding AI usage. " + summaries.joined(separator: ". ")
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

    var displayedServices: [ServiceUsage] {
        let enabledServices = [
            (showClaude, claudeUsage, "claude", "Claude Code", "CC"),
            (showCodex, codexUsage, "codex", "Codex", "CX"),
            (showWindsurf, windsurfUsage, "windsurf", "Windsurf", "W")
        ]

        return enabledServices.compactMap { isEnabled, usage, id, displayName, shortLabel in
            guard isEnabled else { return nil }
            if let usage { return usage }
            guard !hasUnlockedProtectedAccess else { return nil }
            return Self.waitingUsage(id: id, displayName: displayName, shortLabel: shortLabel)
        }
    }

    // MARK: - Private

    nonisolated static func filteredGlobalErrors(allErrors: [String], services: [ServiceUsage]) -> [String] {
        let serviceErrors = Set(services.compactMap(\.error))
        return allErrors.filter { !serviceErrors.contains($0) }
    }

    nonisolated static func retryingFetchUsage(previous: ServiceUsage?) -> ServiceUsage? {
        guard let previous, previous.error != nil else { return previous }
        return nil
    }

    nonisolated static func waitingUsage(id: String, displayName: String, shortLabel: String) -> ServiceUsage {
        ServiceUsage(
            id: id,
            displayName: displayName,
            shortLabel: shortLabel,
            windows: [],
            lastUpdated: .distantPast,
            error: "Click Refresh to load usage."
        )
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

    nonisolated static func nextPollingInterval(
        baseInterval: TimeInterval,
        results: [RefreshResult]
    ) -> TimeInterval {
        let retryIntervals = results.compactMap { result -> TimeInterval? in
            switch result {
            case .rateLimited(let retryAfter):
                if let retryAfter {
                    return min(retryAfter + 30, maxAutomaticRetryInterval)
                }
                return min(baseInterval * 2, maxAutomaticRetryInterval)
            case .skipped, .success, .failure:
                return nil
            }
        }

        return retryIntervals.max() ?? baseInterval
    }

    private func checkPrerequisitesAsync() async {
        let claudeBinaryInstalled = await claudeService.checkInstalled()
        let claudeHasCredentialFile = await claudeService.hasCredentialFile()
        let claudeStatus = Self.claudePrerequisiteStatus(
            isInstalled: claudeBinaryInstalled,
            hasCredentialFile: claudeHasCredentialFile
        )
        let cxi = await codexService.checkInstalled()
        let cxl = await codexService.isLoggedIn()
        let wi = await windsurfService.checkInstalled()
        let wl = await windsurfService.isLoggedIn()

        claudeInstalled = claudeStatus.installed
        claudeLoggedIn = claudeStatus.loggedIn
        codexInstalled = cxi
        codexLoggedIn = cxl
        windsurfInstalled = wi
        windsurfLoggedIn = wl

        if showClaude {
            if let error = claudeStatus.error {
                errors.append(error)
            }
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

    private func fetchClaude() async -> RefreshResult {
        guard showClaude else {
            claudeUsage = nil
            return .skipped
        }
        guard claudeInstalled, claudeLoggedIn else { return .skipped }
        claudeUsage = Self.retryingFetchUsage(previous: claudeUsage)

        do {
            let usage = try await claudeService.fetchUsage()
            claudeUsage = usage
            cacheStore.save(usage)
            notifyIfEnabled(for: usage)
            return .success
        } catch let error as UsageError {
            switch error {
            case .rateLimited(let retryAfter):
                let retryText = retryAfter.map { " (retry in \(Int($0))s)" } ?? ""
                errors.append("Claude Code: rate limited\(retryText) - will retry automatically")
                return .rateLimited(retryAfter: retryAfter)
            case .authExpired:
                await claudeService.invalidateCredentialCache()
                lastPrerequisitesCheck = nil // Force re-check login status next poll
                errors.append(error.localizedDescription)
                claudeUsage = ServiceUsage(
                    id: "claude", displayName: "Claude Code", shortLabel: "CC",
                    windows: [], lastUpdated: Date(), error: error.localizedDescription
                )
                if let claudeUsage { cacheStore.save(claudeUsage) }
                return .failure
            default:
                errors.append(error.localizedDescription)
                claudeUsage = ServiceUsage(
                    id: "claude", displayName: "Claude Code", shortLabel: "CC",
                    windows: [], lastUpdated: Date(), error: error.localizedDescription
                )
                return .failure
            }
        } catch is DecodingError {
            let message = "Claude Code: unexpected API response format"
            errors.append(message)
            claudeUsage = ServiceUsage(
                id: "claude", displayName: "Claude Code", shortLabel: "CC",
                windows: [], lastUpdated: Date(), error: message
            )
            return .failure
        } catch {
            let message = "Claude Code: \(error.localizedDescription)"
            errors.append(message)
            claudeUsage = ServiceUsage(
                id: "claude", displayName: "Claude Code", shortLabel: "CC",
                windows: [], lastUpdated: Date(), error: message
            )
            return .failure
        }
    }

    private func fetchCodex() async -> RefreshResult {
        guard showCodex else {
            codexUsage = nil
            return .skipped
        }
        guard codexInstalled, codexLoggedIn else { return .skipped }
        codexUsage = Self.retryingFetchUsage(previous: codexUsage)

        do {
            let usage = try await codexService.fetchUsage()
            codexUsage = usage
            cacheStore.save(usage)
            notifyIfEnabled(for: usage)
            return .success
        } catch let error as UsageError {
            switch error {
            case .rateLimited(let retryAfter):
                let retryText = retryAfter.map { " (retry in \(Int($0))s)" } ?? ""
                errors.append("Codex: rate limited\(retryText) - will retry automatically")
                return .rateLimited(retryAfter: retryAfter)
            case .authExpired:
                lastPrerequisitesCheck = nil
                errors.append(error.localizedDescription)
                codexUsage = ServiceUsage(
                    id: "codex", displayName: "Codex", shortLabel: "CX",
                    windows: [], lastUpdated: Date(), error: error.localizedDescription
                )
                if let codexUsage { cacheStore.save(codexUsage) }
                return .failure
            default:
                errors.append(error.localizedDescription)
                codexUsage = ServiceUsage(
                    id: "codex", displayName: "Codex", shortLabel: "CX",
                    windows: [], lastUpdated: Date(), error: error.localizedDescription
                )
                return .failure
            }
        } catch is DecodingError {
            let message = "Codex: unexpected API response format"
            errors.append(message)
            codexUsage = ServiceUsage(
                id: "codex", displayName: "Codex", shortLabel: "CX",
                windows: [], lastUpdated: Date(), error: message
            )
            return .failure
        } catch {
            let message = "Codex: \(error.localizedDescription)"
            errors.append(message)
            codexUsage = ServiceUsage(
                id: "codex", displayName: "Codex", shortLabel: "CX",
                windows: [], lastUpdated: Date(), error: message
            )
            return .failure
        }
    }

    private func fetchWindsurf(preferLiveRefresh: Bool = false) async -> RefreshResult {
        guard showWindsurf else {
            windsurfUsage = nil
            return .skipped
        }
        guard windsurfInstalled, windsurfLoggedIn else { return .skipped }

        do {
            let usage = try await windsurfService.fetchUsage(preferLiveRefresh: preferLiveRefresh)
            windsurfUsage = usage
            cacheStore.save(usage)
            if let error = usage.error {
                errors.append(error)
            } else {
                notifyIfEnabled(for: usage)
            }
            return .success
        } catch let error as UsageError {
            errors.append(error.localizedDescription)
            windsurfUsage = Self.windsurfFailureUsage(
                message: error.localizedDescription,
                previous: windsurfUsage
            )
            if let windsurfUsage { cacheStore.save(windsurfUsage) }
            return .failure
        } catch is DecodingError {
            let message = "Windsurf: unexpected local state format"
            errors.append(message)
            windsurfUsage = Self.windsurfFailureUsage(message: message, previous: windsurfUsage)
            if let windsurfUsage { cacheStore.save(windsurfUsage) }
            return .failure
        } catch {
            let message = "Windsurf: \(error.localizedDescription)"
            errors.append(message)
            windsurfUsage = Self.windsurfFailureUsage(message: message, previous: windsurfUsage)
            if let windsurfUsage { cacheStore.save(windsurfUsage) }
            return .failure
        }
    }

    nonisolated static func claudePrerequisiteStatus(
        isInstalled: Bool,
        hasCredentialFile: Bool
    ) -> (installed: Bool, loggedIn: Bool, error: String?) {
        let ready = isInstalled || hasCredentialFile
        return (
            installed: ready,
            loggedIn: ready,
            error: ready ? nil : "Claude Code not installed"
        )
    }

    private func notifyIfEnabled(for usage: ServiceUsage) {
        guard notificationsEnabled else { return }
        notificationService.checkAndNotify(service: usage, threshold: alertThreshold)
    }

    private func restoreCachedUsage() {
        claudeUsage = cacheStore.load(id: "claude")
        codexUsage = cacheStore.load(id: "codex")
        windsurfUsage = cacheStore.load(id: "windsurf")
    }

    private func syncLaunchAtLoginState() {
        launchAtLogin = launchAtLoginController.currentStatus()
    }

    private func menuBarSummary(for usage: ServiceUsage?, visible: Bool) -> String? {
        guard visible, let usage else { return nil }
        if let error = usage.error {
            return "\(usage.displayName) unavailable: \(error)"
        }

        let windowSummary = usage.windows.map {
            "\($0.name) \($0.remainingPercent) percent remaining"
        }
        .joined(separator: ", ")

        guard !windowSummary.isEmpty else {
            return "\(usage.displayName) status unavailable"
        }

        return "\(usage.displayName): \(windowSummary)"
    }
}
