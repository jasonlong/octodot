import Observation

@MainActor
@Observable
final class SettingsViewState {
    var selectedTab: SettingsView.Tab = .account
}
