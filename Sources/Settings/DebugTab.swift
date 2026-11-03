import SwiftUI

// Debug tab: dev bundles only (see SettingsTab.visibleCases).

struct DebugSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard(title: "Overlay", icon: "wrench.and.screwdriver",
                             subtitle: "Show the recording overlay with simulated audio levels") {
                    HStack {
                        Button(appState.isDebugOverlayActive ? "Stop Debug Overlay" : "Debug Overlay") {
                            appState.toggleDebugOverlay()
                        }
                        Spacer()
                    }
                }
                SettingsCard(title: "Update Overlay", icon: "arrow.down.circle",
                             subtitle: "Simulate the post-dictation update reminder") {
                    VStack(spacing: 10) {
                        FormRow(title: "Show after dictation") {
                            Toggle("", isOn: $appState.debugShowsUpdateReminderAfterDictation)
                                .labelsHidden()
                        }
                        HStack {
                            Button("Show Update Overlay Now") {
                                appState.showDebugUpdateAvailableOverlay()
                            }
                            Spacer()
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}
