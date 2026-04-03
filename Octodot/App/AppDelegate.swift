import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct LaunchConfiguration {
        let userDefaults: UserDefaults
        let bootstrapToken: String?
    }

    let preferences: AppPreferences
    let appState: AppState
    lazy var settingsWindowController = SettingsWindowController(
        appState: appState,
        preferences: preferences
    )
    private var statusItemController: StatusItemController?

    override init() {
        let configuration = Self.launchConfiguration(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        self.preferences = AppPreferences(userDefaults: configuration.userDefaults)
        self.appState = AppState(
            userDefaults: configuration.userDefaults,
            bootstrapToken: configuration.bootstrapToken
        )
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
            settingsWindowController: settingsWindowController
        )
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
                bootstrapToken: nil
            )
        }

        return LaunchConfiguration(
            userDefaults: .standard,
            bootstrapToken: tokenLoader()
        )
    }
}
