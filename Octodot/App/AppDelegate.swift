import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum TerminationPolicy: Equatable {
        case terminateNow
        case drainPendingActions
        case cancelInstallAndDrainPendingActions
    }

    struct LaunchConfiguration {
        let userDefaults: UserDefaults
        let bootstrapToken: String?
        let useMockData: Bool
        let shouldShowPanelOnLaunch: Bool
    }

    private static let firstRunPanelPresentedKey = "AppDelegate.firstRunPanelPresented.v1"
    static let terminationDrainTimeoutNanoseconds: UInt64 = 3_000_000_000

    private let launchConfiguration: LaunchConfiguration
    let preferences: AppPreferences
    let appState: AppState
    let updateChecker: UpdateChecker
    lazy var settingsWindowController = SettingsWindowController(
        appState: appState,
        preferences: preferences,
        updateChecker: updateChecker
    )
    private var statusItemController: StatusItemController?
    private let terminationCoordinator = ApplicationTerminationCoordinator()

    override init() {
        let configuration = Self.launchConfiguration(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        self.launchConfiguration = configuration
        self.preferences = AppPreferences(userDefaults: configuration.userDefaults)
        self.appState = AppState(
            userDefaults: configuration.userDefaults,
            bootstrapToken: configuration.bootstrapToken,
            useMockData: configuration.useMockData
        )
        self.updateChecker = UpdateChecker(userDefaults: configuration.userDefaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.shouldLaunchUI(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        guard statusItemController == nil else { return }

        DebugTrace.reset()
        DebugTrace.log("app launch")
        statusItemController = StatusItemController(
            appState: appState,
            preferences: preferences,
            updateChecker: updateChecker,
            settingsWindowController: settingsWindowController
        )
        updateChecker.checkForUpdatesIfNeeded()
        if launchConfiguration.shouldShowPanelOnLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.statusItemController?.showPanelOnFirstRun()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let policy = Self.terminationPolicy(
            hasPendingThreadActions: appState.hasPendingThreadActions,
            isInstallingUpdate: updateChecker.isInstallingUpdate,
            isTerminatingAfterSuccessfulUpdate: updateChecker.isTerminatingAfterSuccessfulUpdate
        )

        return terminationCoordinator.begin(
            policy: policy,
            drainPendingActions: { [appState] in
                guard appState.hasPendingThreadActions else { return true }
                return await appState.drainPendingActions(
                    timeoutNanoseconds: Self.terminationDrainTimeoutNanoseconds
                )
            },
            cancelInstall: { [updateChecker] in
                await updateChecker.cancelInstallForApplicationTermination()
            },
            reply: { [sender] in
                sender.reply(toApplicationShouldTerminate: true)
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationCoordinator.cancel()
        statusItemController = nil
    }

    func showSettings() {
        settingsWindowController.show()
    }

    static func shouldLaunchUI(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    static func shouldUseFirstRunExperience(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if arguments.contains("--first-run") {
            return true
        }

        guard let value = environment["OCTODOT_FIRST_RUN"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return ["1", "true", "yes"].contains(value)
    }

    static func launchConfiguration(
        arguments: [String],
        environment: [String: String],
        tokenLoader: () -> String? = { KeychainHelper.loadToken() }
    ) -> LaunchConfiguration {
        if !shouldLaunchUI(environment: environment) {
            let suiteName = "com.octodot.app.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            return LaunchConfiguration(
                userDefaults: defaults,
                bootstrapToken: nil,
                useMockData: false,
                shouldShowPanelOnLaunch: false
            )
        }

        let useFirstRunExperience = shouldUseFirstRunExperience(
            arguments: arguments,
            environment: environment
        )

        if useFirstRunExperience {
            let suiteName = "com.octodot.app.first-run.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            return LaunchConfiguration(
                userDefaults: defaults,
                bootstrapToken: nil,
                useMockData: false,
                shouldShowPanelOnLaunch: true
            )
        }

        let defaults = UserDefaults.standard
        let bootstrapToken = tokenLoader()
        #if DEBUG
        let useMockData = bootstrapToken == nil
        #else
        let useMockData = false
        #endif
        return LaunchConfiguration(
            userDefaults: defaults,
            bootstrapToken: bootstrapToken,
            useMockData: useMockData,
            shouldShowPanelOnLaunch: shouldShowPanelOnLaunch(
                bootstrapToken: bootstrapToken,
                userDefaults: defaults
            )
        )
    }

    static func shouldShowPanelOnLaunch(bootstrapToken: String?, userDefaults: UserDefaults) -> Bool {
        guard bootstrapToken == nil else { return false }
        guard userDefaults.bool(forKey: firstRunPanelPresentedKey) == false else { return false }
        userDefaults.set(true, forKey: firstRunPanelPresentedKey)
        return true
    }

    static func terminationPolicy(
        hasPendingThreadActions: Bool,
        isInstallingUpdate: Bool,
        isTerminatingAfterSuccessfulUpdate: Bool
    ) -> TerminationPolicy {
        if isTerminatingAfterSuccessfulUpdate {
            return hasPendingThreadActions ? .drainPendingActions : .terminateNow
        }
        if isInstallingUpdate {
            return .cancelInstallAndDrainPendingActions
        }
        return hasPendingThreadActions ? .drainPendingActions : .terminateNow
    }
}

@MainActor
final class ApplicationTerminationCoordinator {
    typealias AsyncOperation = @MainActor @Sendable () async -> Bool
    typealias Reply = @MainActor @Sendable () -> Void

    private var terminationTask: Task<Void, Never>?
    private var didReply = false

    func begin(
        policy: AppDelegate.TerminationPolicy,
        drainPendingActions: @escaping AsyncOperation,
        cancelInstall: @escaping AsyncOperation,
        reply: @escaping Reply
    ) -> NSApplication.TerminateReply {
        guard terminationTask == nil, !didReply else {
            return .terminateLater
        }
        guard policy != .terminateNow else {
            return .terminateNow
        }

        terminationTask = Task { @MainActor [weak self] in
            let actionsDrained: Bool
            let installCleanupFinished: Bool

            switch policy {
            case .terminateNow:
                return
            case .drainPendingActions:
                actionsDrained = await drainPendingActions()
                installCleanupFinished = true
            case .cancelInstallAndDrainPendingActions:
                async let pendingActionsResult = drainPendingActions()
                async let installCleanupResult = cancelInstall()
                (actionsDrained, installCleanupFinished) = await (
                    pendingActionsResult,
                    installCleanupResult
                )
            }

            DebugTrace.log(
                "termination cleanup actions=\(actionsDrained) update=\(installCleanupFinished)"
            )
            guard let self, !didReply else { return }
            didReply = true
            terminationTask = nil
            reply()
        }
        return .terminateLater
    }

    func cancel() {
        terminationTask?.cancel()
        terminationTask = nil
    }
}
