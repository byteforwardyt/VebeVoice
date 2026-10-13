import SwiftUI

struct VoiceEngineSettingsScreen: View {
    let theme: AppTheme

    @StateObject private var viewModel: VoiceEngineSettingsViewModel

    init(appServices: AppServices, theme: AppTheme) {
        self.theme = theme
        _viewModel = StateObject(wrappedValue: VoiceEngineSettingsViewModel(
            settings: SettingsStore.shared,
            appServices: appServices
        ))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VoiceEngineSettingsView(
                viewModel: self.viewModel,
                settings: self.viewModel.settings,
                theme: self.theme
            )
            .vibePageContentColumn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
