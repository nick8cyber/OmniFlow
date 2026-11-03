import SwiftUI
import AppKit

// Dictation tab: everything about the recording interaction — microphone,
// shortcuts, overlay, languages, Edit Mode, and paste/audio behaviour.

struct DictationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("overlay_display_id") private var overlayDisplayID = 0

    @State private var screenCacheBuster = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                microphoneCard
                shortcutsCard
                overlayCard
                languagesCard
                editModeCard
                pastingCard
            }
            .padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screenCacheBuster += 1
        }
    }

    // MARK: Microphone

    private var microphoneCard: some View {
        SettingsCard(title: "Microphone", icon: "mic.fill") {
            VStack(spacing: 6) {
                MicrophoneOptionRow(title: "System Default",
                                    isSelected: appState.selectedMicrophoneID == "default"
                                        || appState.selectedMicrophoneID.isEmpty) {
                    appState.selectedMicrophoneID = "default"
                }
                ForEach(appState.availableMicrophones) { device in
                    MicrophoneOptionRow(title: device.name,
                                        isSelected: appState.selectedMicrophoneID == device.uid) {
                        appState.selectedMicrophoneID = device.uid
                    }
                }
            }
            .onAppear {
                appState.refreshAvailableMicrophones()
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsCard: some View {
        SettingsCard(title: "Shortcuts", icon: "keyboard.fill", subtitle: "Click a binding to re-record it") {
            VStack(spacing: 12) {
                DictationShortcutEditor(onCaptureStateChange: { capturing in
                    if capturing {
                        appState.suspendHotkeyMonitoringForShortcutCapture()
                    } else {
                        appState.resumeHotkeyMonitoringAfterShortcutCapture()
                    }
                })
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcut Start Delay: \(appState.shortcutStartDelayMilliseconds) ms")
                        .font(.caption.weight(.semibold))
                    Slider(value: $appState.shortcutStartDelay, in: 0...0.5, step: 0.025)
                    Text("The delay is applied before recording starts for both shortcuts. Stopping is always immediate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Overlay

    private var overlayCard: some View {
        SettingsCard(title: "Overlay", icon: "rectangle.dashed", subtitle: "What you see while recording") {
            VStack(spacing: 12) {
                OverlayPreviewCard()
                FormRow(title: "Show on") {
                    Picker("Show on", selection: $overlayDisplayID) {
                        Text("Active window (default)").tag(0)
                        Text("Primary display").tag(-1)
                        ForEach(NSScreen.screens, id: \.self) { screen in
                            Text(screen.localizedName).tag(Int(screen.displayID))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    .id(screenCacheBuster)
                }
            }
        }
    }

    // MARK: Languages

    private var languagesCard: some View {
        SettingsCard(title: "Languages", icon: "globe") {
            VStack(spacing: 12) {
                FormRow(title: "Spoken language",
                        subtitle: "Hint for the transcription model — pick the language whose alphabet matches your speech") {
                    Picker("Spoken language", selection: $appState.transcriptionLanguage) {
                        ForEach(AppState.transcriptionLanguageOptions, id: \.code) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Divider()
                FormRow(title: "Output language",
                        subtitle: "When set, OmniFlow translates your speech into the selected language") {
                    Picker("Output language", selection: $appState.outputLanguage) {
                        Text("Same as spoken").tag("")
                        Text("English").tag("English")
                        Text("Chinese (Simplified)").tag("Chinese (Simplified)")
                        Text("Chinese (Traditional)").tag("Chinese (Traditional)")
                        Text("Spanish").tag("Spanish")
                        Text("French").tag("French")
                        Text("Japanese").tag("Japanese")
                        Text("Korean").tag("Korean")
                        Text("German").tag("German")
                        Text("Portuguese").tag("Portuguese")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    // MARK: Edit Mode

    private var editModeCard: some View {
        SettingsCard(title: "Edit Mode", icon: "pencil",
                     subtitle: "Transform selected text with a spoken instruction") {
            VStack(spacing: 10) {
                FormRow(title: "Enable Edit Mode") {
                    Toggle("", isOn: Binding(
                        get: { appState.isCommandModeEnabled },
                        set: { _ = appState.setCommandModeEnabled($0) }))
                        .toggleStyle(.switch)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Invocation Style", selection: Binding(
                        get: { appState.commandModeStyle },
                        set: { _ = appState.setCommandModeStyle($0) })) {
                        Text("Automatic").tag(CommandModeStyle.automatic)
                        Text("Manual").tag(CommandModeStyle.manual)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!appState.isCommandModeEnabled)
                    if appState.commandModeStyle == .automatic {
                        Text("If text is selected, your normal dictation shortcut transforms the selection instead of dictating over it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Hold the extra modifier together with your normal dictation shortcut to transform selected text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Extra Modifier", selection: Binding(
                            get: { appState.commandModeManualModifier },
                            set: { _ = appState.setCommandModeManualModifier($0) })) {
                            Text("Cmd ⌘").tag(CommandModeManualModifier.command)
                            Text("Ctrl ⌃").tag(CommandModeManualModifier.control)
                            Text("Option ⌥").tag(CommandModeManualModifier.option)
                            Text("Shift ⇧").tag(CommandModeManualModifier.shift)
                        }
                        .pickerStyle(.segmented)
                        .disabled(!appState.isCommandModeEnabled || appState.commandModeStyle != .manual)
                    }
                    if let message = appState.commandModeManualModifierValidationMessage {
                        Label(message, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .opacity(appState.isCommandModeEnabled ? 1 : 0.5)
                .disabled(!appState.isCommandModeEnabled)
            }
        }
    }

    // MARK: Pasting & audio

    private var pastingCard: some View {
        SettingsCard(title: "Pasting & Audio", icon: "doc.on.clipboard") {
            VStack(spacing: 12) {
                FormRow(title: "Mute audio when dictation starts",
                        subtitle: "System audio is restored when the dictation ends") {
                    Toggle("", isOn: $appState.dictationAudioInterruptionEnabled)
                        .toggleStyle(.switch)
                }
                Divider()
                FormRow(title: "Preserve clipboard after paste") {
                    Toggle("", isOn: $appState.preserveClipboard)
                        .toggleStyle(.switch)
                }
                FormRow(title: "Keep dictations in clipboard history") {
                    Toggle("", isOn: $appState.keepDictationInClipboardHistory)
                        .toggleStyle(.switch)
                }
                FormRow(title: "Say \"press enter\" to submit after paste") {
                    Toggle("", isOn: $appState.isPressEnterVoiceCommandEnabled)
                        .toggleStyle(.switch)
                }
            }
        }
    }
}
