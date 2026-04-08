import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct LaunchConfiguration {
        let userDefaults: UserDefaults
        let bootstrapToken: String?
        let shouldShowPanelOnLaunch: Bool
    }

    private static let firstRunPanelPresentedKey = "AppDelegate.firstRunPanelPresented.v1"

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

    override init() {
        let configuration = Self.launchConfiguration(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        self.launchConfiguration = configuration
        self.preferences = AppPreferences(userDefaults: configuration.userDefaults)
        self.appState = AppState(
            userDefaults: configuration.userDefaults,
            bootstrapToken: configuration.bootstrapToken
        )
        self.updateChecker = UpdateChecker(userDefaults: configuration.userDefaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.shouldLaunchUI(environment: ProcessInfo.processInfo.environment) else {
            return
        }

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
                shouldShowPanelOnLaunch: true
            )
        }

        let defaults = UserDefaults.standard
        let bootstrapToken = tokenLoader()
        return LaunchConfiguration(
            userDefaults: defaults,
            bootstrapToken: bootstrapToken,
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
}
