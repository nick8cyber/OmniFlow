import SwiftUI

// Root of the Settings window: sidebar with the tab list plus the selected
// tab's content. The window itself is created in AppDelegate (NSWindow +
// NSHostingView) because the app has no SwiftUI Window scenes.

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentPanel
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.visibleCases) { tab in
                SettingsSidebarRow(tab: tab,
                                   isSelected: appState.selectedSettingsTab == tab)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.selectedSettingsTab = tab
                    }
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 188, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var contentPanel: some View {
        switch appState.selectedSettingsTab ?? .general {
        case .general:
            GeneralSettingsView()
        case .dictation:
            DictationSettingsView()
        case .provider:
            AIProviderSettingsView()
        case .processing:
            ProcessingSettingsView()
        case .macros:
            VoiceMacrosSettingsView()
        case .runLog:
            RunLogView()
        case .debug:
            DebugSettingsView()
        }
    }
}

struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
            Text(tab.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            Spacer(minLength: 0)
        }
        .foregroundColor(isSelected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }
}
