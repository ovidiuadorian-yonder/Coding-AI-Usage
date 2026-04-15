import XCTest
@testable import CodingAIUsage

@MainActor
final class UsageViewModelTests: XCTestCase {
    func testNextPollingIntervalUsesLongestRateLimitDelay() {
        let interval = UsageViewModel.nextPollingInterval(
            baseInterval: 300,
            results: [
                .success,
                .rateLimited(retryAfter: 45),
                .rateLimited(retryAfter: nil)
            ]
        )

        XCTAssertEqual(interval, 600)
    }

    func testNextPollingIntervalFallsBackToBaseWhenNoRateLimitsOccur() {
        let interval = UsageViewModel.nextPollingInterval(
            baseInterval: 300,
            results: [.success, .failure, .skipped]
        )

        XCTAssertEqual(interval, 300)
    }

    func testInitSynchronizesLaunchAtLoginStateFromSystemController() {
        let launchController = TestLaunchAtLoginController(isEnabled: true)

        let viewModel = UsageViewModel(
            notificationService: NotificationService(
                requestPermissionHandler: { completion in completion(true) },
                configureAuthorizationHandler: { _ in }
            ),
            launchAtLoginController: launchController,
            autostart: false
        )

        XCTAssertTrue(viewModel.launchAtLogin)
    }

    func testSetLaunchAtLoginKeepsStoredValueInSyncWhenControllerThrows() {
        let launchController = TestLaunchAtLoginController(
            isEnabled: true,
            setEnabledError: LaunchAtLoginControllerError.operationFailed
        )

        let viewModel = UsageViewModel(
            notificationService: NotificationService(
                requestPermissionHandler: { completion in completion(true) },
                configureAuthorizationHandler: { _ in }
            ),
            launchAtLoginController: launchController,
            autostart: false
        )
        viewModel.errors.removeAll()

        viewModel.setLaunchAtLogin(false)

        XCTAssertTrue(viewModel.launchAtLogin)
        XCTAssertEqual(viewModel.errors.last, "Launch at Login: unable to update login item (operationFailed)")
    }

    func testNotificationsAreRequestedOnlyWhenExplicitlyEnabled() {
        UserDefaults.standard.removeObject(forKey: "notificationsEnabled")

        var requestCount = 0
        let notificationService = NotificationService(
            requestPermissionHandler: { completion in
                requestCount += 1
                completion(true)
            },
            configureAuthorizationHandler: { _ in }
        )

        let viewModel = UsageViewModel(
            notificationService: notificationService,
            launchAtLoginController: TestLaunchAtLoginController(isEnabled: false),
            autostart: false
        )

        XCTAssertFalse(viewModel.notificationsEnabled)
        XCTAssertEqual(requestCount, 0)

        viewModel.setNotificationsEnabled(true)

        XCTAssertTrue(viewModel.notificationsEnabled)
        XCTAssertEqual(requestCount, 1)
    }

    func testGlobalErrorsExcludeServiceSpecificErrors() {
        let windsurf = ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [],
            lastUpdated: .distantPast,
            error: "Windsurf: daily/weekly quota unavailable"
        )

        let errors = UsageViewModel.filteredGlobalErrors(
            allErrors: ["Windsurf: daily/weekly quota unavailable", "Codex: rate limited"],
            services: [windsurf]
        )

        XCTAssertEqual(errors, ["Codex: rate limited"])
    }

    func testRetryingFetchClearsPreviousServiceErrorUsage() {
        let previous = ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [],
            lastUpdated: .distantPast,
            error: "Claude Code: session expired - please re-login in Claude Code"
        )

        XCTAssertNil(UsageViewModel.retryingFetchUsage(previous: previous))
    }

    func testRetryingFetchKeepsPreviousHealthyUsage() {
        let previous = ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [
                UsageWindow(id: "five_hour", name: "5-Hour", compactLabel: "5h", utilization: 0.50, resetTime: nil)
            ],
            lastUpdated: .distantPast,
            error: nil
        )

        XCTAssertEqual(UsageViewModel.retryingFetchUsage(previous: previous)?.error, nil)
        XCTAssertEqual(UsageViewModel.retryingFetchUsage(previous: previous)?.windows.count, 1)
    }

    func testWindsurfFailureUsageClearsPreviousQuotaWindows() {
        let previous = ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [
                UsageWindow(id: "daily", name: "Daily", compactLabel: "d", utilization: 0.01, resetTime: nil),
                UsageWindow(id: "weekly", name: "Weekly", compactLabel: "w", utilization: 0.19, resetTime: nil)
            ],
            lastUpdated: .distantPast,
            error: nil,
            footerLines: ["Plan ends Apr 22, 2026", "$1371.44"]
        )

        let usage = UsageViewModel.windsurfFailureUsage(
            message: "Windsurf: unexpected local state format",
            previous: previous
        )

        XCTAssertEqual(usage.error, "Windsurf: unexpected local state format")
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertTrue(usage.footerLines.isEmpty)
    }

    func testClaudePrerequisitesTreatInstalledBinaryAsReadyWithoutCredentialFile() {
        let status = UsageViewModel.claudePrerequisiteStatus(
            isInstalled: true,
            hasCredentialFile: false
        )

        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.loggedIn)
        XCTAssertNil(status.error)
    }

    func testManualRefreshDoesNotInvalidateClaudeCredentialCache() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-manual-refresh-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try? FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"{"claudeAiOauth":{"accessToken":"file-token","expiresAt":9999999999999}}"#
            .write(to: filePath, atomically: true, encoding: .utf8)

        var invalidationCount = 0
        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            onInvalidate: { invalidationCount += 1 }
        )
        let claudeService = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = Data(#"{"five_hour":{"utilization":20,"resets_at":"2026-04-03T18:00:00.000Z"},"seven_day":{"utilization":40,"resets_at":"2026-04-08T18:00:00.000Z"}}"#.utf8)
                return (data, response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil }
        )

        let viewModel = UsageViewModel(
            claudeService: claudeService,
            autostart: false
        )
        viewModel.showCodex = false
        viewModel.showWindsurf = false

        _ = try? loader.loadAnyCredentials()
        XCTAssertEqual(loader.cacheState.cachedAccessToken, "file-token")

        await viewModel.performManualRefresh(forceLiveWindsurf: false)

        XCTAssertEqual(invalidationCount, 0)
    }

    func testClaudeDecodeFailurePreservesCachedHealthySnapshot() async {
        let cacheStore = InMemoryUsageCacheStore()
        cacheStore.save(
            ServiceUsage(
                id: "claude",
                displayName: "Claude Code",
                shortLabel: "CC",
                windows: [
                    UsageWindow(id: "five_hour", name: "5-Hour", compactLabel: "5h", utilization: 0.2, resetTime: nil)
                ],
                lastUpdated: .distantPast,
                error: nil
            )
        )

        let viewModel = UsageViewModel(
            claudeService: ClaudeFailingUsageSpy(error: Self.decodingError()),
            cacheStore: cacheStore,
            autostart: false
        )
        viewModel.showClaude = true
        viewModel.showCodex = false
        viewModel.showWindsurf = false

        await viewModel.performManualRefresh(forceLiveWindsurf: false)

        // In-memory state surfaces the error for display
        XCTAssertEqual(viewModel.claudeUsage?.error, "Claude Code: unexpected API response format")
        // Cache still holds the last successful snapshot — not overwritten by the transient failure
        XCTAssertNil(cacheStore.load(id: "claude")?.error)
        XCTAssertFalse(cacheStore.load(id: "claude")?.windows.isEmpty ?? true)
    }

    func testCodexDecodeFailurePreservesCachedHealthySnapshot() async {
        let cacheStore = InMemoryUsageCacheStore()
        cacheStore.save(
            ServiceUsage(
                id: "codex",
                displayName: "Codex",
                shortLabel: "CX",
                windows: [
                    UsageWindow(id: "five_hour", name: "5-Hour", compactLabel: "5h", utilization: 0.3, resetTime: nil)
                ],
                lastUpdated: .distantPast,
                error: nil
            )
        )

        let viewModel = UsageViewModel(
            codexService: CodexFailingUsageSpy(error: Self.decodingError()),
            cacheStore: cacheStore,
            autostart: false
        )
        viewModel.showClaude = false
        viewModel.showCodex = true
        viewModel.showWindsurf = false

        await viewModel.performManualRefresh(forceLiveWindsurf: false)

        // In-memory state surfaces the error for display
        XCTAssertEqual(viewModel.codexUsage?.error, "Codex: unexpected API response format")
        // Cache still holds the last successful snapshot — not overwritten by the transient failure
        XCTAssertNil(cacheStore.load(id: "codex")?.error)
        XCTAssertFalse(cacheStore.load(id: "codex")?.windows.isEmpty ?? true)
    }

    func testAutostartDefersProtectedResourceChecksUntilManualRefresh() async throws {
        UserDefaults.standard.set(true, forKey: "showClaude")
        UserDefaults.standard.set(true, forKey: "showCodex")
        UserDefaults.standard.set(true, forKey: "showWindsurf")

        let claudeUsage = ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [UsageWindow(id: "five_hour", name: "5-Hour", compactLabel: "5h", utilization: 0.2, resetTime: nil)],
            lastUpdated: .distantPast,
            error: nil
        )
        let codexUsage = ServiceUsage(
            id: "codex",
            displayName: "Codex",
            shortLabel: "CX",
            windows: [UsageWindow(id: "five_hour", name: "5-Hour", compactLabel: "5h", utilization: 0.3, resetTime: nil)],
            lastUpdated: .distantPast,
            error: nil
        )
        let windsurfUsage = ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [UsageWindow(id: "daily", name: "Daily", compactLabel: "d", utilization: 0.1, resetTime: nil)],
            lastUpdated: .distantPast,
            error: nil
        )

        let claudeService = ClaudeUsageSpy(usage: claudeUsage)
        let codexService = CodexUsageSpy(usage: codexUsage)
        let windsurfService = WindsurfUsageSpy(usage: windsurfUsage)

        let viewModel = UsageViewModel(
            claudeService: claudeService,
            codexService: codexService,
            windsurfService: windsurfService,
            notificationService: NotificationService(
                requestPermissionHandler: { completion in completion(false) },
                configureAuthorizationHandler: { _ in }
            ),
            scheduler: PollingScheduler(interval: 0.01),
            autostart: true
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        let initialClaudeCounts = await claudeService.snapshot()
        let initialCodexCounts = await codexService.snapshot()
        let initialWindsurfCounts = await windsurfService.snapshot()

        XCTAssertEqual(initialClaudeCounts.checkInstalledCallCount, 0)
        XCTAssertEqual(initialClaudeCounts.hasCredentialFileCallCount, 0)
        XCTAssertEqual(initialClaudeCounts.fetchUsageCallCount, 0)
        XCTAssertEqual(initialCodexCounts.checkInstalledCallCount, 0)
        XCTAssertEqual(initialCodexCounts.isLoggedInCallCount, 0)
        XCTAssertEqual(initialCodexCounts.fetchUsageCallCount, 0)
        XCTAssertEqual(initialWindsurfCounts.checkInstalledCallCount, 0)
        XCTAssertEqual(initialWindsurfCounts.isLoggedInCallCount, 0)
        XCTAssertTrue(initialWindsurfCounts.fetchUsageArguments.isEmpty)

        await viewModel.performManualRefresh(forceLiveWindsurf: false)

        let finalClaudeCounts = await claudeService.snapshot()
        let finalCodexCounts = await codexService.snapshot()
        let finalWindsurfCounts = await windsurfService.snapshot()

        XCTAssertGreaterThan(finalClaudeCounts.checkInstalledCallCount, 0)
        XCTAssertGreaterThan(finalClaudeCounts.fetchUsageCallCount, 0)
        XCTAssertGreaterThan(finalCodexCounts.checkInstalledCallCount, 0)
        XCTAssertGreaterThan(finalCodexCounts.fetchUsageCallCount, 0)
        XCTAssertGreaterThan(finalWindsurfCounts.checkInstalledCallCount, 0)
        XCTAssertEqual(finalWindsurfCounts.fetchUsageArguments, [false])
    }

    func testManualRefreshButtonForcesLiveWindsurf() async throws {
        let claudeService = ClaudeUsageSpy(
            usage: ServiceUsage(
                id: "claude",
                displayName: "Claude Code",
                shortLabel: "CC",
                windows: [],
                lastUpdated: .distantPast,
                error: nil
            )
        )
        let codexService = CodexUsageSpy(
            usage: ServiceUsage(
                id: "codex",
                displayName: "Codex",
                shortLabel: "CX",
                windows: [],
                lastUpdated: .distantPast,
                error: nil
            )
        )
        let windsurfService = WindsurfUsageSpy(
            usage: ServiceUsage(
                id: "windsurf",
                displayName: "Windsurf",
                shortLabel: "W",
                windows: [],
                lastUpdated: .distantPast,
                error: nil
            )
        )

        let viewModel = UsageViewModel(
            claudeService: claudeService,
            codexService: codexService,
            windsurfService: windsurfService,
            autostart: false
        )

        viewModel.showClaude = false
        viewModel.showCodex = false
        viewModel.showWindsurf = true

        viewModel.manualRefresh()
        try await Task.sleep(nanoseconds: 100_000_000)

        let finalClaudeCounts = await claudeService.snapshot()
        let finalWindsurfCounts = await windsurfService.snapshot()

        XCTAssertEqual(finalClaudeCounts.invalidateCredentialCacheCallCount, 0)
        XCTAssertEqual(finalWindsurfCounts.fetchUsageArguments, [true])
    }

    func testDisplayedServicesShowWaitingPlaceholdersBeforeFirstRefresh() {
        let viewModel = UsageViewModel(
            cacheStore: InMemoryUsageCacheStore(),
            autostart: false
        )
        viewModel.showClaude = true
        viewModel.showCodex = true
        viewModel.showWindsurf = true

        let services = viewModel.displayedServices

        XCTAssertEqual(services.map(\.id), ["claude", "codex", "windsurf"])
        XCTAssertEqual(
            services.map(\.error),
            Array(repeating: "Click Refresh to load usage.", count: 3)
        )
    }

    func testInitLoadsCachedServiceUsageBeforeFirstRefresh() {
        let cacheStore = InMemoryUsageCacheStore()
        let cachedClaude = ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [
                UsageWindow(id: "five_hour", name: "5-Hour", compactLabel: "5h", utilization: 0.2, resetTime: nil)
            ],
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            error: nil
        )
        cacheStore.save(cachedClaude)

        let viewModel = UsageViewModel(
            cacheStore: cacheStore,
            autostart: false
        )
        viewModel.showClaude = true
        viewModel.showCodex = false
        viewModel.showWindsurf = false

        XCTAssertEqual(viewModel.claudeUsage?.id, "claude")
        XCTAssertEqual(viewModel.claudeUsage?.primaryWindow?.remainingPercent, 80)
        XCTAssertEqual(viewModel.displayedServices.map(\.id), ["claude"])
        XCTAssertNil(viewModel.displayedServices.first?.error)
    }

    func testUserDefaultsCacheStoreRoundTripsServiceUsage() {
        let suiteName = "UsageViewModelTests.\(#function).\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let cacheStore = UserDefaultsUsageCacheStore(userDefaults: userDefaults)
        let usage = ServiceUsage(
            id: "codex",
            displayName: "Codex",
            shortLabel: "CX",
            windows: [
                UsageWindow(id: "five_hour", name: "5-Hour", compactLabel: "5h", utilization: 0.35, resetTime: nil)
            ],
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_100),
            error: nil,
            footerLines: ["Updated from cache"]
        )

        cacheStore.save(usage)

        let restored = cacheStore.load(id: "codex")

        XCTAssertEqual(restored?.id, "codex")
        XCTAssertEqual(restored?.primaryWindow?.remainingPercent, 65)
        XCTAssertEqual(restored?.footerLines, ["Updated from cache"])
    }

    private static func decodingError() -> DecodingError {
        DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Malformed response")
        )
    }
}

private enum LaunchAtLoginControllerError: Error {
    case operationFailed
}

private final class TestLaunchAtLoginController: LaunchAtLoginControlling {
    private(set) var isEnabled: Bool
    private let setEnabledError: Error?

    init(isEnabled: Bool, setEnabledError: Error? = nil) {
        self.isEnabled = isEnabled
        self.setEnabledError = setEnabledError
    }

    func currentStatus() -> Bool {
        isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if let setEnabledError {
            throw setEnabledError
        }
        isEnabled = enabled
    }
}

private actor ClaudeUsageSpy: ClaudeUsageServing {
    struct Snapshot {
        let fetchUsageCallCount: Int
        let checkInstalledCallCount: Int
        let hasCredentialFileCallCount: Int
        let invalidateCredentialCacheCallCount: Int
    }

    private let usage: ServiceUsage
    private(set) var fetchUsageCallCount = 0
    private(set) var checkInstalledCallCount = 0
    private(set) var hasCredentialFileCallCount = 0
    private(set) var invalidateCredentialCacheCallCount = 0

    init(usage: ServiceUsage) {
        self.usage = usage
    }

    func fetchUsage() async throws -> ServiceUsage {
        fetchUsageCallCount += 1
        return usage
    }

    func checkInstalled() async -> Bool {
        checkInstalledCallCount += 1
        return true
    }

    func hasCredentialFile() async -> Bool {
        hasCredentialFileCallCount += 1
        return true
    }

    func invalidateCredentialCache() async {
        invalidateCredentialCacheCallCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            fetchUsageCallCount: fetchUsageCallCount,
            checkInstalledCallCount: checkInstalledCallCount,
            hasCredentialFileCallCount: hasCredentialFileCallCount,
            invalidateCredentialCacheCallCount: invalidateCredentialCacheCallCount
        )
    }
}

private actor CodexUsageSpy: CodexUsageServing {
    struct Snapshot {
        let fetchUsageCallCount: Int
        let checkInstalledCallCount: Int
        let isLoggedInCallCount: Int
    }

    private let usage: ServiceUsage
    private(set) var fetchUsageCallCount = 0
    private(set) var checkInstalledCallCount = 0
    private(set) var isLoggedInCallCount = 0

    init(usage: ServiceUsage) {
        self.usage = usage
    }

    func fetchUsage() async throws -> ServiceUsage {
        fetchUsageCallCount += 1
        return usage
    }

    func checkInstalled() async -> Bool {
        checkInstalledCallCount += 1
        return true
    }

    func isLoggedIn() async -> Bool {
        isLoggedInCallCount += 1
        return true
    }

    func snapshot() -> Snapshot {
        Snapshot(
            fetchUsageCallCount: fetchUsageCallCount,
            checkInstalledCallCount: checkInstalledCallCount,
            isLoggedInCallCount: isLoggedInCallCount
        )
    }
}

private actor ClaudeFailingUsageSpy: ClaudeUsageServing {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func fetchUsage() async throws -> ServiceUsage {
        throw error
    }

    func checkInstalled() async -> Bool {
        true
    }

    func hasCredentialFile() async -> Bool {
        true
    }

    func invalidateCredentialCache() async {}
}

private actor CodexFailingUsageSpy: CodexUsageServing {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func fetchUsage() async throws -> ServiceUsage {
        throw error
    }

    func checkInstalled() async -> Bool {
        true
    }

    func isLoggedIn() async -> Bool {
        true
    }
}

private actor WindsurfUsageSpy: WindsurfUsageServing {
    struct Snapshot {
        let checkInstalledCallCount: Int
        let isLoggedInCallCount: Int
        let fetchUsageArguments: [Bool]
    }

    private let usage: ServiceUsage
    private(set) var checkInstalledCallCount = 0
    private(set) var isLoggedInCallCount = 0
    private(set) var fetchUsageArguments: [Bool] = []

    init(usage: ServiceUsage) {
        self.usage = usage
    }

    func fetchUsage(preferLiveRefresh: Bool) async throws -> ServiceUsage {
        fetchUsageArguments.append(preferLiveRefresh)
        return usage
    }

    func checkInstalled() async -> Bool {
        checkInstalledCallCount += 1
        return true
    }

    func isLoggedIn() async -> Bool {
        isLoggedInCallCount += 1
        return true
    }

    func snapshot() -> Snapshot {
        Snapshot(
            checkInstalledCallCount: checkInstalledCallCount,
            isLoggedInCallCount: isLoggedInCallCount,
            fetchUsageArguments: fetchUsageArguments
        )
    }
}

private final class InMemoryUsageCacheStore: UsageCacheStoring {
    private var values: [String: ServiceUsage] = [:]

    func load(id: String) -> ServiceUsage? {
        values[id]
    }

    func save(_ usage: ServiceUsage) {
        values[usage.id] = usage
    }
}
