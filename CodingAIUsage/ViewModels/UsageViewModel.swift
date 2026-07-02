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
    @AppStorage("alertThreshold") var alertThreshold: Double = 0.10
    @AppStorage("launchAtLogin") var launchAtLogin = false

    private let claudeService: any ClaudeUsageServing
    private let codexService: any CodexUsageServing
    private let windsurfService: any WindsurfUsageServing
    private let notificationService: NotificationService
    private let claudeAuthLauncher: ClaudeAuthLauncher
    private let launchAtLoginController: LaunchAtLoginControlling
    private let cacheStore: any UsageCacheStoring
    private var hasUnlockedProtectedAccess = false

    // Refreshes happen only on user action: opening the menu bar window or
    // clicking Refresh. Menu-open refreshes are throttled so re-opening the
    // menu repeatedly does not hammer the APIs, and are paused entirely while
    // a provider reports a rate limit.
    private(set) var lastRefreshCompleted: Date?
    private(set) var rateLimitedUntil: Date?
    nonisolated static let menuOpenRefreshThrottle: TimeInterval = 60
    nonisolated static let defaultRateLimitPause: TimeInterval = 300

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

    init(
        claudeService: (any ClaudeUsageServing)? = nil,
        codexService: (any CodexUsageServing)? = nil,
        windsurfService: (any WindsurfUsageServing)? = nil,
        notificationService: NotificationService? = nil,
        claudeAuthLauncher: ClaudeAuthLauncher = ClaudeAuthLauncher(),
        launchAtLoginController: LaunchAtLoginControlling = SystemLaunchAtLoginController(),
        cacheStore: (any UsageCacheStoring)? = nil,
        autostart: Bool = true
    ) {
        self.claudeService = claudeService ?? ClaudeUsageService()
        self.codexService = codexService ?? CodexUsageService()
        self.windsurfService = windsurfService ?? WindsurfUsageService()
        self.notificationService = notificationService ?? NotificationService()
        self.claudeAuthLauncher = claudeAuthLauncher
        self.launchAtLoginController = launchAtLoginController
        self.cacheStore = cacheStore ?? UserDefaultsUsageCacheStore()
        syncLaunchAtLoginState()
        restoreCachedUsage()

        guard autostart else { return }

        if notificationsEnabled {
            self.notificationService.requestPermission()
        }
        // On wake, only invalidate stale local state — never fetch. The next
        // fetch happens when the user opens the menu or clicks Refresh.
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.claudeService.invalidateCredentialCache()
                self.lastPrerequisitesCheck = nil
            }
        }
    }

    deinit {
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
    }

    func refresh(
        forceLiveWindsurf: Bool = true,
        userInitiated: Bool = false
    ) async {
        isRefreshing = true
        errors.removeAll()

        if userInitiated {
            hasUnlockedProtectedAccess = true
        }

        guard hasUnlockedProtectedAccess else {
            isRefreshing = false
            return
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

        lastRefreshCompleted = Date()
        rateLimitedUntil = Self.rateLimitPause(results: results, now: Date())
        isRefreshing = false
    }

    func manualRefresh() {
        Task { @MainActor in
            await performManualRefresh(forceLiveWindsurf: true)
        }
    }

    func performManualRefresh(forceLiveWindsurf: Bool) async {
        lastPrerequisitesCheck = nil
        await refresh(
            forceLiveWindsurf: forceLiveWindsurf,
            userInitiated: true
        )
    }

    /// Called when the menu bar window opens. Refreshes at most once per
    /// `menuOpenRefreshThrottle` and never while a rate limit is in effect —
    /// the explicit Refresh button bypasses both guards.
    func refreshOnMenuOpen() {
        Task { @MainActor in
            // Guard inside the task: refresh() flips isRefreshing before its
            // first suspension, so a second open trigger queued behind this
            // one sees it and bails instead of double-fetching.
            guard Self.shouldAutoRefreshOnMenuOpen(
                lastRefreshCompleted: lastRefreshCompleted,
                rateLimitedUntil: rateLimitedUntil,
                isRefreshing: isRefreshing,
                now: Date()
            ) else { return }

            await refresh(forceLiveWindsurf: false, userInitiated: true)
        }
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

        if showClaude, let claude = claudeUsage, claude.error == nil, !claude.windows.isEmpty {
            let fh = claude.fiveHourWindow.map { "\($0.remainingPercent)" } ?? "--"
            let w = claude.weeklyWindow.map { "\($0.remainingPercent)" } ?? "--"
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

    nonisolated static func rateLimitPause(
        results: [RefreshResult],
        now: Date,
        defaultPause: TimeInterval = UsageViewModel.defaultRateLimitPause
    ) -> Date? {
        let pauses = results.compactMap { result -> TimeInterval? in
            guard case .rateLimited(let retryAfter) = result else { return nil }
            return retryAfter ?? defaultPause
        }

        return pauses.max().map { now.addingTimeInterval($0) }
    }

    nonisolated static func shouldAutoRefreshOnMenuOpen(
        lastRefreshCompleted: Date?,
        rateLimitedUntil: Date?,
        isRefreshing: Bool,
        now: Date,
        throttle: TimeInterval = UsageViewModel.menuOpenRefreshThrottle
    ) -> Bool {
        guard !isRefreshing else { return false }
        if let rateLimitedUntil, now < rateLimitedUntil { return false }
        if let lastRefreshCompleted, now.timeIntervalSince(lastRefreshCompleted) < throttle { return false }
        return true
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
                let retryText = retryAfter.map { " - try again in \(Int($0))s" } ?? " - try again later"
                errors.append("Claude Code: rate limited\(retryText)")
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
                let retryText = retryAfter.map { " - try again in \(Int($0))s" } ?? " - try again later"
                errors.append("Codex: rate limited\(retryText)")
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
