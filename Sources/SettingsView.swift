import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement

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
        .frame(width: 180, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var contentPanel: some View {
        switch appState.selectedSettingsTab ?? .general {
        case .general:
            GeneralSettingsView()
        case .prompts:
            PromptsSettingsView()
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
        HStack(spacing: 8) {
            Image(systemName: tab.icon)
                .font(.system(size: 13))
                .frame(width: 16, height: 16)
            Text(tab.title)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var githubCache = GitHubMetadataCache.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true
    @AppStorage("use_compact_overlay") private var useCompactOverlay = true
    @AppStorage("overlay_display_id") private var overlayDisplayID = 0

    @State private var apiKeyInput = ""
    @State private var apiBaseURLInput = ""
    @State private var transcriptionAPIURLInput = ""
    @State private var transcriptionAPIKeyInput = ""
    @State private var customVocabularyDraft = ""
    @State private var postProcessingModelDraft = AppState.defaultPostProcessingModel
    @State private var postProcessingFallbackModelDraft = AppState.defaultPostProcessingFallbackModel
    @State private var contextModelDraft = AppState.defaultContextModel
    @State private var transcriptionModelDraft = AppState.defaultTranscriptionModel
    @State private var isValidatingKey = false
    @State private var keyValidationSucceeded = false
    @State private var keyValidationFailureMessage: String?
    @State private var micPermissionGranted = false
    @State private var checkingForUpdates = false
    @State private var volumePreviewHintVisible = false
    @State private var launchAtLoginNeedsApproval = false
    @State private var screenCacheBuster = 0
    @FocusState private var vocabularyFieldFocused: Bool
    private let micPermissionPollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                brandingHeader
                appCard
                updatesCard
                apiKeyCard
                outputLanguageCard
                shortcutsCard
                audioDuringDictationCard
                recordingOverlayCard
                editModeCard
                cleanupCard
                clipboardCard
                microphoneCard
                soundVolumeCard
                vocabularyCard
                permissionsCard
                buildCard
            }
            .padding(24)
        }
        .onAppear(perform: initializeFields)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screenCacheBuster += 1
        }
        .onReceive(micPermissionPollTimer) { _ in
            // Accessibility and Screen Recording rows follow AppState's own
            // polling; the microphone row needs its own re-check so granting
            // access in System Settings is picked up while the window is open.
            checkMicPermission()
        }
    }

    private func initializeFields() {
        apiKeyInput = appState.apiKey
        apiBaseURLInput = appState.apiBaseURL
        transcriptionAPIURLInput = appState.transcriptionAPIURL
        transcriptionAPIKeyInput = appState.transcriptionAPIKey
        customVocabularyDraft = appState.customVocabulary
        postProcessingModelDraft = appState.postProcessingModel
        postProcessingFallbackModelDraft = appState.postProcessingFallbackModel
        contextModelDraft = appState.contextModel
        transcriptionModelDraft = appState.transcriptionModel
        checkMicPermission()
        appState.refreshLaunchAtLoginStatus()
        launchAtLoginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        Task { await githubCache.fetchIfNeeded() }
    }

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // 0. Branding header

    private var brandingHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppName.displayName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: "https://avatars.githubusercontent.com/u/992248")) { image in
                    image.resizable().frame(width: 22, height: 22).clipShape(Circle())
                } placeholder: {
                    Circle().fill(Color.secondary.opacity(0.3)).frame(width: 22, height: 22)
                }
                Button("nick8cyber/OmniFlow") {
                    if let url = URL(string: "https://github.com/nick8cyber/OmniFlow") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(.caption, design: .monospaced))
                Spacer()
                if let starCount = githubCache.starCount {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").foregroundColor(.yellow)
                        Text("\(starCount.formatted()) \(starCount == 1 ? "star" : "stars")")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                }
                Button("Star") {
                    if let url = URL(string: "https://github.com/nick8cyber/OmniFlow") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.yellow.opacity(0.18)))
            }
            if !githubCache.recentStargazers.isEmpty {
                HStack(spacing: -6) {
                    ForEach(githubCache.recentStargazers, id: \.id) { stargazer in
                        GitHubAvatarView(avatarURL: stargazer.user.avatarThumbnailUrl,
                                         profileURL: stargazer.user.htmlUrl)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    // 1. App

    private var appCard: some View {
        SettingsCard(title: "App", icon: "power") {
            Toggle("Launch \(AppName.displayName) at login", isOn: $appState.launchAtLogin)
            if launchAtLoginNeedsApproval {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Login item requires approval in System Settings.")
                        .font(.caption)
                    Button("Open Login Items Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                }
            }
            Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
            if !showMenuBarIcon {
                Text("Turn it back on in Settings, or relaunch the app to reopen Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // 2. Updates

    private var updatesCard: some View {
        SettingsCard(title: "Updates", icon: "arrow.triangle.2.circlepath") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updateManager.autoCheckEnabled },
                set: { updateManager.autoCheckEnabled = $0 }))
            HStack {
                Button {
                    checkingForUpdates = true
                    Task {
                        await updateManager.checkForUpdates(userInitiated: true)
                        checkingForUpdates = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if checkingForUpdates || updateManager.isChecking {
                            ProgressView().controlSize(.small)
                            Text("Checking...")
                        } else {
                            Text("Check for Updates Now")
                        }
                    }
                }
                .disabled(checkingForUpdates || updateManager.isChecking || updateManager.updateStatus != .idle)
                Spacer()
            }
            if let lastCheck = updateManager.lastCheckDate {
                Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if updateManager.updateAvailable {
                updateStatusBlock
            }
        }
    }

    @ViewBuilder
    private var updateStatusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch updateManager.updateStatus {
            case .idle:
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
                    Text(updateManager.latestReleaseVersion.isEmpty
                        ? "A new version of \(AppName.displayName) is available!"
                        : "\(AppName.displayName) v\(updateManager.latestReleaseVersion) is available!")
                    Spacer()
                    Button("What's New") {
                        updateManager.showReleaseNotes()
                    }
                    Button("Update Now") {
                        if let release = updateManager.latestRelease {
                            updateManager.downloadAndInstall(release: release)
                        }
                    }
                }
            case .downloading:
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Downloading update...")
                        ProgressView(value: updateManager.downloadProgress ?? 0)
                        Text("\(Int((updateManager.downloadProgress ?? 0) * 100))%")
                            .font(.caption)
                        Button("Cancel") {
                            updateManager.cancelDownload()
                        }
                    }
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing update...")
                }
            case .readyToRelaunch:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Relaunching...")
                }
            case .error(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text(message).font(.caption)
                    Button("Retry") {
                        updateManager.updateStatus = .idle
                        if let release = updateManager.latestRelease {
                            updateManager.downloadAndInstall(release: release)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.1)))
    }

    // 3. API Key

    private var apiKeyCard: some View {
        SettingsCard(title: "API Key", icon: "key.fill") {
            Text("Paste the API key of your OpenAI-compatible speech provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField("Enter your Groq API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                    .onChange(of: apiKeyInput) { _ in
                        keyValidationSucceeded = false
                        keyValidationFailureMessage = nil
                    }
                Button(isValidatingKey ? "Validating..." : "Save") {
                    validateAndSaveKey()
                }
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)
            }
            if keyValidationSucceeded {
                Label("API key saved", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
            if let keyValidationFailureMessage {
                Text(keyValidationFailureMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            DisclosureGroup("Advanced Provider Settings") {
                ProviderSettingsFields(showsModelDescription: false)
                    .padding(.top, 8)
            }
        }
    }

    private func validateAndSaveKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isValidatingKey = true
        keyValidationSucceeded = false
        keyValidationFailureMessage = nil
        let baseURL = appState.apiBaseURL.isEmpty ? AppState.defaultAPIBaseURL : appState.apiBaseURL
        Task {
            let outcome = await TranscriptionService.validateAPIKey(trimmed, baseURL: baseURL)
            await MainActor.run {
                isValidatingKey = false
                switch outcome {
                case .valid:
                    appState.apiKey = trimmed
                    keyValidationSucceeded = true
                case .invalidKey:
                    keyValidationFailureMessage = "The provider rejected this API key. Check the key and provider settings, then try again."
                case .unavailable(let detail):
                    keyValidationFailureMessage = "Provider is unreachable — check your connection. \(detail)"
                }
            }
        }
    }

    // 4. Output Language

    private var outputLanguageCard: some View {
        SettingsCard(title: "Output Language", icon: "globe") {
            Picker("Output Language", selection: $appState.outputLanguage) {
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
            .pickerStyle(.menu)
            Text("When set, OmniFlow translates your speech into the selected language.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // 5. Dictation Shortcuts

    private var shortcutsCard: some View {
        SettingsCard(title: "Dictation Shortcuts", icon: "keyboard.fill") {
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

    // 6. Audio During Dictation

    private var audioDuringDictationCard: some View {
        SettingsCard(title: "Audio During Dictation", icon: "speaker.slash.fill") {
            Toggle("Mute audio when dictation starts", isOn: $appState.dictationAudioInterruptionEnabled)
            Text("System audio is restored when the dictation ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // 7. Recording Overlay

    private var recordingOverlayCard: some View {
        SettingsCard(title: "Recording Overlay", icon: "rectangle.dashed") {
            VStack(spacing: 8) {
                OverlayStyleOptionRow(isMinimalist: true, selection: $useCompactOverlay)
                OverlayStyleOptionRow(isMinimalist: false, selection: $useCompactOverlay)
            }
            Divider()
            HStack {
                Text("Show on")
                Spacer()
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

    // 8. Edit Mode

    private var editModeCard: some View {
        SettingsCard(title: "Edit Mode", icon: "pencil") {
            Toggle("Enable Edit Mode", isOn: Binding(
                get: { appState.isCommandModeEnabled },
                set: { _ = appState.setCommandModeEnabled($0) }))
            Text("Transform highlighted text with a spoken instruction instead of dictating over it.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    // 9. Cleanup

    private var cleanupCard: some View {
        SettingsCard(title: "Cleanup", icon: "sparkles") {
            Toggle("Preserve exact wording", isOn: $appState.preserveExactWording)
            Text("When enabled, LLM cleanup is skipped and your words are pasted verbatim. Voice macros and Edit Mode still work. Output Language still translates, but literally.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // 10. Clipboard

    private var clipboardCard: some View {
        SettingsCard(title: "Clipboard", icon: "doc.on.clipboard") {
            Toggle("Preserve clipboard after paste", isOn: $appState.preserveClipboard)
            Divider()
            Toggle("Keep dictations in clipboard history", isOn: $appState.keepDictationInClipboardHistory)
            Divider()
            Toggle("Say \"press enter\" to submit after paste", isOn: $appState.isPressEnterVoiceCommandEnabled)
        }
    }

    // 11. Microphone

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

    // 12. Sound Volume

    private var soundVolumeCard: some View {
        SettingsCard(title: "Sound Volume", icon: "speaker.wave.2.fill") {
            Toggle("Play alert sounds", isOn: $appState.alertSoundsEnabled)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)
                Slider(value: $appState.soundVolume, in: 0...1, step: 0.1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.secondary)
                Text("\(Int(appState.soundVolume * 100))%")
                    .font(.caption)
                    .frame(width: 36, alignment: .trailing)
            }
            .disabled(!appState.alertSoundsEnabled)
            .opacity(appState.alertSoundsEnabled ? 1 : 0.5)
            HStack {
                Button("Preview") {
                    let muted = SystemAudioStatus.isDefaultOutputMuted()
                    let volume = SystemAudioStatus.defaultOutputVolume() ?? 0
                    withAnimation(.easeInOut(duration: 0.2)) {
                        volumePreviewHintVisible = muted || volume < 0.10
                    }
                    appState.playAlertSound(named: "Tink")
                }
                Spacer()
            }
            if volumePreviewHintVisible {
                Label("System volume is muted or very low. Unmute to hear the preview.",
                      systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onChange(of: appState.alertSoundsEnabled) { _ in
            volumePreviewHintVisible = false
        }
    }

    // 13. Custom Vocabulary

    private var vocabularyCard: some View {
        SettingsCard(title: "Custom Vocabulary", icon: "text.book.closed.fill") {
            TextEditor(text: $customVocabularyDraft)
                .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                .frame(minHeight: 80, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .focused($vocabularyFieldFocused)
                .onExitCommand {
                    commitVocabulary()
                }
            Text("Separate terms with commas, new lines, or semicolons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear {
            commitVocabulary()
        }
        .onChange(of: appState.customVocabulary) { newValue in
            // External writes (e.g. "Paste Custom Word to Vocabulary" from the
            // menu bar) must not be rolled back by the onDisappear commit.
            // Same pattern as the provider draft fields: follow appState while
            // the field is not being edited.
            if !vocabularyFieldFocused {
                customVocabularyDraft = newValue
            }
        }
    }

    private func commitVocabulary() {
        appState.customVocabulary = customVocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 14. Permissions

    private var permissionsCard: some View {
        SettingsCard(title: "Permissions", icon: "lock.shield.fill") {
            VStack(spacing: 10) {
                permissionRow(icon: "mic.fill",
                              title: "Microphone",
                              granted: micPermissionGranted) {
                    appState.requestMicrophoneAccess { granted in
                        micPermissionGranted = granted
                    }
                }
                permissionRow(icon: "hand.raised.fill",
                              title: "Accessibility",
                              granted: appState.hasAccessibility) {
                    appState.openAccessibilitySettings()
                }
                permissionRow(icon: "camera.viewfinder",
                              title: "Screen Recording",
                              granted: appState.hasScreenRecordingPermission) {
                    appState.requestScreenCapturePermission()
                }
            }
            .onAppear {
                checkMicPermission()
            }
        }
    }

    private func permissionRow(icon: String, title: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            Text(title)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant Access", action: action)
                    .controlSize(.small)
            }
        }
    }

    // 15. Build

    private var buildCard: some View {
        SettingsCard(title: "Build", icon: "info.circle.fill") {
            let buildTag = Bundle.main.infoDictionary?["OmniFlowBuildTag"] as? String
                ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                ?? "unknown"
            HStack {
                Text("Build number")
                Spacer()
                Text(buildTag)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Divider()
            BuildCopyRow(version: appVersion, build: buildTag)
        }
    }
}

private struct BuildCopyRow: View {
    let version: String
    let build: String

    @State private var copied = false
    @State private var resetWorkItem: DispatchWorkItem?

    private var diagnostics: String {
        var architecture = "unknown"
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #endif
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(AppName.displayName) \(version) (\(build))\nmacOS \(osVersion) (\(architecture))"
    }

    var body: some View {
        HStack {
            Text(diagnostics)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(diagnostics, forType: .string)
                copied = true
                resetWorkItem?.cancel()
                let workItem = DispatchWorkItem { copied = false }
                resetWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
            }
        }
    }
}

// MARK: - Microphone row

struct MicrophoneOptionRow: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary)
                Text(title)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Provider fields

struct ProviderSettingsFields: View {
    @EnvironmentObject private var appState: AppState
    let showsModelDescription: Bool

    @State private var baseURLDraft = ""
    @State private var postProcessingModelDraft = ""
    @State private var postProcessingFallbackModelDraft = ""
    @State private var contextModelDraft = ""
    @State private var transcriptionModelDraft = ""
    @State private var transcriptionLanguageDraft = ""
    @State private var transcriptionAPIURLDraft = ""
    @State private var transcriptionAPIKeyDraft = ""
    @State private var realtimeStreamingModelDraft = ""
    @FocusState private var baseURLFieldFocused: Bool
    @FocusState private var transcriptionAPIURLFieldFocused: Bool
    @FocusState private var transcriptionAPIKeyFieldFocused: Bool
    @FocusState private var realtimeModelFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Base URL")
                    .font(.caption.weight(.semibold))
                Text("Change this to use a different OpenAI-compatible API provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField(AppState.defaultAPIBaseURL, text: $baseURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .focused($baseURLFieldFocused)
                        .onSubmit(commitBaseURL)
                    Button("Reset to Default") {
                        baseURLDraft = ""
                        commitBaseURL()
                    }
                    .font(.caption)
                }
                .onChange(of: baseURLFieldFocused) { focused in
                    if !focused { commitBaseURL() }
                }
            }

            if showsModelDescription {
                Text("If you use another provider, enter that provider's model IDs here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ModelDropdownView(title: "Post-Processing Model",
                              subtitle: "Used for transcript cleanup and Edit Mode transforms.",
                              predefinedModels: ModelConfiguration.llmModels,
                              defaultModel: AppState.defaultPostProcessingModel,
                              textDraft: $postProcessingModelDraft,
                              onCommit: { appState.postProcessingModel = normalized(postProcessingModelDraft) },
                              onReset: {
                                  postProcessingModelDraft = AppState.defaultPostProcessingModel
                                  appState.postProcessingModel = AppState.defaultPostProcessingModel
                              })
            CooldownWarningView(model: appState.postProcessingModel,
                                message: { time in "Daily limit reached — resets at \(time)" })

            ModelDropdownView(title: "Post-Processing Fallback Model",
                              subtitle: "Used as the explicit retry model when the primary model fails.",
                              predefinedModels: ModelConfiguration.llmModels,
                              defaultModel: AppState.defaultPostProcessingFallbackModel,
                              textDraft: $postProcessingFallbackModelDraft,
                              onCommit: { appState.postProcessingFallbackModel = normalized(postProcessingFallbackModelDraft) },
                              onReset: {
                                  postProcessingFallbackModelDraft = AppState.defaultPostProcessingFallbackModel
                                  appState.postProcessingFallbackModel = AppState.defaultPostProcessingFallbackModel
                              })
            CooldownWarningView(model: appState.postProcessingFallbackModel,
                                message: { time in "Fallback daily limit reached — resets at \(time)" })

            ModelDropdownView(title: "Context Model",
                              subtitle: "Used for context inference, with a text-only retry when screenshot analysis fails. Screenshot analysis requires a model that accepts image input.",
                              predefinedModels: ModelConfiguration.visionModels,
                              defaultModel: AppState.defaultContextModel,
                              textDraft: $contextModelDraft,
                              onCommit: { appState.contextModel = normalized(contextModelDraft) },
                              onReset: {
                                  contextModelDraft = AppState.defaultContextModel
                                  appState.contextModel = AppState.defaultContextModel
                              })

            ModelDropdownView(title: "Transcription Model",
                              subtitle: "Used for speech-to-text transcription.",
                              predefinedModels: ModelConfiguration.transcriptionModels,
                              defaultModel: AppState.defaultTranscriptionModel,
                              textDraft: $transcriptionModelDraft,
                              onCommit: { appState.transcriptionModel = normalized(transcriptionModelDraft) },
                              onReset: {
                                  transcriptionModelDraft = AppState.defaultTranscriptionModel
                                  appState.transcriptionModel = AppState.defaultTranscriptionModel
                              })

            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription Language")
                    .font(.caption.weight(.semibold))
                Picker("Transcription Language", selection: $transcriptionLanguageDraft) {
                    ForEach(AppState.transcriptionLanguageOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                Text("Pick a language whose alphabet matches your speech to avoid wrong-script characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription API URL")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Uses API Base URL when empty", text: $transcriptionAPIURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .focused($transcriptionAPIURLFieldFocused)
                        .onSubmit(commitTranscriptionAPIURL)
                    if !transcriptionAPIURLDraft.isEmpty {
                        Button("Clear") {
                            transcriptionAPIURLDraft = ""
                            commitTranscriptionAPIURL()
                        }
                        .font(.caption)
                    }
                }
                .onChange(of: transcriptionAPIURLFieldFocused) { focused in
                    if !focused { commitTranscriptionAPIURL() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription API Key")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    SecureField("Uses API Key when empty", text: $transcriptionAPIKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .focused($transcriptionAPIKeyFieldFocused)
                        .onSubmit(commitTranscriptionAPIKey)
                    if !transcriptionAPIKeyDraft.isEmpty {
                        Button("Clear") {
                            transcriptionAPIKeyDraft = ""
                            commitTranscriptionAPIKey()
                        }
                        .font(.caption)
                    }
                }
                .onChange(of: transcriptionAPIKeyFieldFocused) { focused in
                    if !focused { commitTranscriptionAPIKey() }
                }
            }

            Divider()

            Toggle("Stream audio while recording (realtime)", isOn: $appState.realtimeStreamingEnabled)
            Text("Streams microphone audio over the provider's /v1/realtime WebSocket while recording, falling back to file transcription when the stream fails.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Realtime Transcription Model")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Required by some providers, e.g. gpt-4o-transcribe", text: $realtimeStreamingModelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .focused($realtimeModelFieldFocused)
                        .onSubmit(commitRealtimeModel)
                    if !realtimeStreamingModelDraft.isEmpty {
                        Button("Reset") {
                            realtimeStreamingModelDraft = ""
                            commitRealtimeModel()
                        }
                        .font(.caption)
                    }
                }
                .onChange(of: realtimeModelFieldFocused) { focused in
                    if !focused { commitRealtimeModel() }
                }
                Text("Used only for realtime streaming; the file pipeline always uses the Transcription Model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reloadDrafts)
        .onChange(of: appState.postProcessingModel) { newValue in
            if !isEditing(postProcessingModelDraft, appState.postProcessingModel) { postProcessingModelDraft = newValue }
        }
        .onChange(of: appState.transcriptionAPIURL) { newValue in
            if !transcriptionAPIURLFieldFocused { transcriptionAPIURLDraft = newValue }
        }
        .onChange(of: appState.transcriptionAPIKey) { newValue in
            if !transcriptionAPIKeyFieldFocused { transcriptionAPIKeyDraft = newValue }
        }
    }

    private func isEditing(_ draft: String, _ committed: String) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != committed
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reloadDrafts() {
        baseURLDraft = appState.apiBaseURL
        postProcessingModelDraft = appState.postProcessingModel
        postProcessingFallbackModelDraft = appState.postProcessingFallbackModel
        contextModelDraft = appState.contextModel
        transcriptionModelDraft = appState.transcriptionModel
        transcriptionLanguageDraft = appState.transcriptionLanguage
        transcriptionAPIURLDraft = appState.transcriptionAPIURL
        transcriptionAPIKeyDraft = appState.transcriptionAPIKey
        realtimeStreamingModelDraft = appState.realtimeStreamingModel
    }

    private func commitBaseURL() {
        let trimmed = normalized(baseURLDraft)
        appState.apiBaseURL = trimmed
        baseURLDraft = trimmed
    }

    private func commitTranscriptionAPIURL() {
        let trimmed = normalized(transcriptionAPIURLDraft)
        appState.transcriptionAPIURL = trimmed
        transcriptionAPIURLDraft = trimmed
    }

    private func commitTranscriptionAPIKey() {
        let trimmed = normalized(transcriptionAPIKeyDraft)
        appState.transcriptionAPIKey = trimmed
        transcriptionAPIKeyDraft = trimmed
    }

    private func commitRealtimeModel() {
        appState.realtimeStreamingModel = normalized(realtimeStreamingModelDraft)
    }
}

private struct CooldownWarningView: View {
    let model: String
    let message: (String) -> String

    @State private var now = Date()
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let expiry = UserDefaults.standard.object(forKey: LLMCooldownManager.udKey(for: model)) as? Double
        Group {
            if let expiry, expiry > now.timeIntervalSince1970 {
                Label(message(Self.formatTime(Date(timeIntervalSince1970: expiry))),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onReceive(timer) { date in
            now = date
        }
    }

    private static func formatTime(_ date: Date) -> String {
        let sameDay = Calendar.current.isDate(date, inSameDayAs: Date())
        return date.formatted(date: sameDay ? .omitted : .abbreviated,
                              time: .shortened)
    }
}

// MARK: - Prompts

struct PromptsSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SystemPromptCard()
                InstructionGuardCard()
                ContextPromptCard()
            }
            .padding(24)
        }
    }
}

private struct SystemPromptCard: View {
    @EnvironmentObject private var appState: AppState

    @State private var draft = ""
    @State private var showDefault = false
    @State private var testInput = "Um, so I was like, thinking we should uh, refactor the authentication module, you know?"
    @State private var testRunning = false
    @State private var testResult: String?
    @State private var testPrompt: String?
    @State private var testError: String?

    var body: some View {
        SettingsCard(title: "System Prompt", icon: "text.bubble.fill") {
            promptStatusBadge(custom: appState.customSystemPrompt)
            TextEditor(text: $draft)
                .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .onExitCommand { commit() }
            HStack {
                if !appState.customSystemPrompt.isEmpty {
                    Button("Reset to Default") {
                        appState.customSystemPrompt = ""
                        appState.customSystemPromptLastModified = ""
                        draft = PostProcessingService.defaultSystemPrompt
                    }
                }
                Spacer()
                Button {
                    showDefault.toggle()
                } label: {
                    Text(showDefault ? "Hide Default" : "View Default")
                }
            }
            if showDefault {
                ScrollView {
                    Text(PostProcessingService.defaultSystemPrompt)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
            newerDefaultNotice(custom: appState.customSystemPrompt,
                               lastModified: appState.customSystemPromptLastModified,
                               defaultDate: PostProcessingService.defaultSystemPromptDate,
                               reset: {
                                   appState.customSystemPrompt = ""
                                   appState.customSystemPromptLastModified = ""
                                   draft = PostProcessingService.defaultSystemPrompt
                               })
            Divider()
            Text("Test how the prompt cleans a raw transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Test transcript", text: $testInput)
                .textFieldStyle(.roundedBorder)
            Button {
                runTest()
            } label: {
                HStack(spacing: 6) {
                    if testRunning {
                        ProgressView().controlSize(.small)
                        Text("Running...")
                    } else {
                        Image(systemName: "play.fill")
                        Text("Test System Prompt")
                    }
                }
            }
            .disabled(testRunning || appState.apiKey.isEmpty || testInput.isEmpty)
            if appState.apiKey.isEmpty {
                Label("API key required to test", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if let testError {
                Label(testError, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if let testResult {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Result: \(testResult.isEmpty ? "(empty — no output)" : testResult)",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                    if let testPrompt {
                        DisclosureGroup("Full prompt sent") {
                            ScrollView {
                                Text(testPrompt)
                                    .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .onAppear {
            draft = appState.customSystemPrompt.isEmpty
                ? PostProcessingService.defaultSystemPrompt
                : appState.customSystemPrompt
        }
        .onDisappear {
            commit()
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == PostProcessingService.defaultSystemPrompt {
            appState.customSystemPrompt = ""
            appState.customSystemPromptLastModified = ""
        } else {
            appState.customSystemPrompt = trimmed
            appState.customSystemPromptLastModified = Self.dateFormatter.string(from: Date())
        }
    }

    private func runTest() {
        commit()
        testRunning = true
        testResult = nil
        testPrompt = nil
        testError = nil
        let service = PostProcessingService(
            apiKey: appState.apiKey,
            baseURL: appState.apiBaseURL.isEmpty ? AppState.defaultAPIBaseURL : appState.apiBaseURL,
            preferredModel: appState.postProcessingModel,
            preferredFallbackModel: appState.postProcessingFallbackModel,
            instructionExecutionGuardEnabled: appState.instructionExecutionGuardEnabled)
        let context = AppContext(appName: "\(AppName.displayName) Settings",
                                 bundleIdentifier: "com.nick8cyber.omniflow",
                                 windowTitle: "System Prompt Test",
                                 selectedText: nil,
                                 currentActivity: "User is testing the system prompt in \(AppName.displayName) settings.",
                                 contextSystemPrompt: nil,
                                 contextPrompt: nil,
                                 screenshotDataURL: nil,
                                 screenshotMimeType: nil,
                                 screenshotError: nil)
        let vocabulary = appState.customVocabulary
        let prompt = appState.customSystemPrompt
        Task {
            do {
                let result = try await service.postProcess(transcript: testInput,
                                                           context: context,
                                                           customVocabulary: vocabulary,
                                                           customSystemPrompt: prompt)
                await MainActor.run {
                    testRunning = false
                    testResult = result.transcript
                    testPrompt = result.prompt
                }
            } catch {
                await MainActor.run {
                    testRunning = false
                    testError = error.localizedDescription
                }
            }
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct InstructionGuardCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: "Instruction Guard", icon: "shield.lefthalf.filled") {
            Toggle("Prevent dictated prompts from being executed", isOn: $appState.instructionExecutionGuardEnabled)
            Text("If post-processing looks like it answered your dictation instead of cleaning it, OmniFlow retries and falls back to the literal transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ContextPromptCard: View {
    @EnvironmentObject private var appState: AppState

    @State private var draft = ""
    @State private var showDefault = false
    @State private var testRunning = false
    @State private var testSummary: String?
    @State private var testPrompt: String?
    @State private var testError: String?

    var body: some View {
        SettingsCard(title: "Context Prompt", icon: "eye.fill") {
            promptStatusBadge(custom: appState.customContextPrompt)
            TextEditor(text: $draft)
                .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .onExitCommand { commit() }
            HStack {
                if !appState.customContextPrompt.isEmpty {
                    Button("Reset to Default") {
                        appState.customContextPrompt = ""
                        appState.customContextPromptLastModified = ""
                        draft = AppContextService.defaultContextPrompt
                    }
                }
                Spacer()
                Button {
                    showDefault.toggle()
                } label: {
                    Text(showDefault ? "Hide Default" : "View Default")
                }
            }
            if showDefault {
                ScrollView {
                    Text(AppContextService.defaultContextPrompt)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
            newerDefaultNotice(custom: appState.customContextPrompt,
                               lastModified: appState.customContextPromptLastModified,
                               defaultDate: AppContextService.defaultContextPromptDate,
                               reset: {
                                   appState.customContextPrompt = ""
                                   appState.customContextPromptLastModified = ""
                                   draft = AppContextService.defaultContextPrompt
                               })
            Divider()
            Picker("Screenshot Resolution", selection: $appState.contextScreenshotMaxDimension) {
                ForEach(AppState.contextScreenshotDimensionOptions, id: \.self) { dimension in
                    Text("\(dimension) px").tag(dimension)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text(appState.contextScreenshotMaxDimension
                    == AppState.defaultContextScreenshotMaxDimension ? "Using default" : "Using custom value")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.contextScreenshotMaxDimension
                    != AppState.defaultContextScreenshotMaxDimension {
                    Button("Reset to Default") {
                        appState.contextScreenshotMaxDimension = AppState.defaultContextScreenshotMaxDimension
                    }
                    .font(.caption)
                }
                Spacer()
            }
            Divider()
            Button {
                runTest()
            } label: {
                HStack(spacing: 6) {
                    if testRunning {
                        ProgressView().controlSize(.small)
                        Text("Running...")
                    } else {
                        Image(systemName: "play.fill")
                        Text("Test Context Prompt")
                    }
                }
            }
            .disabled(testRunning || appState.apiKey.isEmpty)
            if let testError {
                Label(testError, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if let testSummary {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result:")
                        .font(.caption.weight(.semibold))
                    Text(testSummary)
                        .font(.caption)
                    if let testPrompt {
                        DisclosureGroup("Full prompt sent") {
                            ScrollView {
                                Text(testPrompt)
                                    .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .onAppear {
            draft = appState.customContextPrompt.isEmpty
                ? AppContextService.defaultContextPrompt
                : appState.customContextPrompt
        }
        .onDisappear {
            commit()
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == AppContextService.defaultContextPrompt {
            appState.customContextPrompt = ""
            appState.customContextPromptLastModified = ""
        } else {
            appState.customContextPrompt = trimmed
            appState.customContextPromptLastModified = SystemPromptCard.dateFormatter.string(from: Date())
        }
    }

    private func runTest() {
        commit()
        testRunning = true
        testSummary = nil
        testPrompt = nil
        testError = nil
        let service = appState.makeAppContextService()
        Task {
            let context = await service.collectContext()
            await MainActor.run {
                testRunning = false
                testSummary = context.currentActivity
                testPrompt = context.contextPrompt
                if context.contextPrompt == nil {
                    testError = "Context inference returned no result. This may be a permissions issue or the API could not be reached."
                }
            }
        }
    }
}

private func promptStatusBadge(custom: String) -> some View {
    HStack {
        if custom.isEmpty {
            Label("Using default", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Using custom prompt", systemImage: "pencil")
                .font(.caption)
                .foregroundColor(.blue)
        }
        Spacer()
    }
}

private func newerDefaultNotice(custom: String, lastModified: String, defaultDate: String,
                                reset: @escaping () -> Void) -> some View {
    Group {
        if !custom.isEmpty && !lastModified.isEmpty && lastModified < defaultDate {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.blue)
                Text("A newer default prompt is available.")
                    .font(.caption)
                Spacer()
                Button("Switch to Default", action: reset)
                    .font(.caption)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
        }
    }
}

// MARK: - Voice Macros

struct VoiceMacrosSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editingMacro: VoiceMacro?
    @State private var showsEditor = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard(title: "Voice Macros", icon: "music.mic") {
                    Text("Bypass post-processing and immediately paste your predefined text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Add Macro") {
                            editingMacro = nil
                            showsEditor = true
                        }
                    }
                    if appState.voiceMacros.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "music.mic")
                                .font(.system(size: 30))
                                .foregroundStyle(.tertiary)
                            Text("No Voice Macros Yet")
                                .font(.headline)
                            Text("Click 'Add Macro' to define your first voice macro.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(appState.voiceMacros) { macro in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(macro.command)
                                            .font(.headline)
                                        Text(macro.payload)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Button("Edit") {
                                        editingMacro = macro
                                        showsEditor = true
                                    }
                                    .font(.caption)
                                    Button("Delete") {
                                        appState.voiceMacros.removeAll { $0.id == macro.id }
                                    }
                                    .font(.caption)
                                    .foregroundColor(.red)
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showsEditor) {
            VoiceMacroEditorView(macro: editingMacro) { command, payload in
                if let editingMacro {
                    if let index = appState.voiceMacros.firstIndex(where: { $0.id == editingMacro.id }) {
                        appState.voiceMacros[index] = VoiceMacro(id: editingMacro.id,
                                                                 command: command,
                                                                 payload: payload)
                    }
                } else {
                    appState.voiceMacros.append(VoiceMacro(command: command, payload: payload))
                }
            }
        }
    }
}

private struct VoiceMacroEditorView: View {
    let macro: VoiceMacro?
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var payload = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(macro == nil ? "Add Macro" : "Edit Macro")
                .font(.headline)
            TextField("e.g. debugging prompt", text: $command)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $payload)
                .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    onSave(command.trimmingCharacters(in: .whitespacesAndNewlines), payload)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || payload.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            command = macro?.command ?? ""
            payload = macro?.payload ?? ""
        }
    }
}

// MARK: - Run Log

struct RunLogView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Log")
                        .font(.headline)
                    Text("Stored locally. Only the \(appState.maxPipelineHistoryCount) most recent runs are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear History") {
                    showsClearConfirmation = true
                }
                .disabled(appState.pipelineHistory.isEmpty)
            }
            if appState.pipelineHistory.isEmpty {
                Spacer()
                Text("No runs yet. Use dictation to populate history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(appState.pipelineHistory) { item in
                            RunLogEntryView(item: item)
                        }
                    }
                }
            }
        }
        .padding(16)
        .confirmationDialog("Delete all \(appState.pipelineHistory.count) runs and their audio?",
                            isPresented: $showsClearConfirmation,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                appState.clearPipelineHistory()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct RunLogEntryView: View {
    @EnvironmentObject private var appState: AppState
    let item: PipelineHistoryItem

    @State private var isExpanded = false
    @State private var copiedTranscript = false
    @State private var copyResetWorkItem: DispatchWorkItem?

    private var isError: Bool {
        item.postProcessingStatus.hasPrefix("Error:")
    }

    private var transcriptPreview: String {
        let text = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = text.isEmpty
            ? item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            : text
        return preview.isEmpty ? "(no transcript)" : preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.timestamp.formatted(date: .numeric, time: .standard))
                        .font(.subheadline.weight(.semibold))
                    Text(transcriptPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                entryButtons
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
            if isExpanded {
                Divider()
                expandedSection
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isError ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1))
        .cornerRadius(10)
    }

    private var entryButtons: some View {
        HStack(spacing: 6) {
            Group {
                if isError && item.audioFileName != nil {
                    if appState.retryingItemIDs.contains(item.id) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 28, height: 28)
                    } else {
                        Button {
                            appState.retryTranscription(item: item)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Retry transcription")
                        .frame(width: 28, height: 28)
                    }
                } else {
                    Color.clear.frame(width: 28, height: 28)
                }
            }
            Button {
                TestCaseExporter.exportWithSavePanel(item: item,
                                                     audioDirURL: AppState.audioStorageDirectory())
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help("Export test case")
            .frame(width: 28, height: 28)
            Button {
                let text = item.postProcessedTranscript.isEmpty ? item.rawTranscript : item.postProcessedTranscript
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                copiedTranscript = true
                copyResetWorkItem?.cancel()
                let workItem = DispatchWorkItem { copiedTranscript = false }
                copyResetWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
            } label: {
                Image(systemName: copiedTranscript ? "checkmark" : "doc.on.doc")
                    .foregroundColor(copiedTranscript ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy transcript")
            .disabled(item.postProcessedTranscript.isEmpty && item.rawTranscript.isEmpty)
            .frame(width: 28, height: 28)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.deleteHistoryEntry(id: item.id)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Delete entry")
            .frame(width: 28, height: 28)
        }
    }

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let audioFileName = item.audioFileName {
                AudioPlayerView(audioURL: AppState.audioStorageDirectory()
                    .appendingPathComponent(audioFileName))
            } else {
                Label("No audio recorded", systemImage: "waveform.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !item.customVocabulary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Vocabulary")
                        .font(.caption.weight(.semibold))
                    FlowLayout(spacing: 4) {
                        ForEach(vocabularyTerms, id: \.self) { term in
                            Text(term)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(4)
                        }
                    }
                }
            }
            PipelineStepView(stepNumber: 1, title: "Capture Context") {
                if let dataURL = item.contextScreenshotDataURL,
                   let base64 = dataURL.split(separator: ",").last,
                   let data = Data(base64Encoded: String(base64)),
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 120)
                }
                PromptDisclosure(prompt: item.contextPrompt)
                Text(item.contextSummary.isEmpty ? "No context captured" : item.contextSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PipelineStepView(stepNumber: 2, title: "Transcribe Audio") {
                Text("Sent audio to the configured transcription model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MonospacedCopyBlock(text: item.rawTranscript.isEmpty ? "(empty transcript)" : item.rawTranscript,
                                    emptyText: item.rawTranscript.isEmpty,
                                    copyTooltip: "Copy literal transcript",
                                    copiedTooltip: "Copied literal transcript")
            }
            PipelineStepView(stepNumber: 3, title: "Post-Process") {
                Text(item.postProcessingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PromptDisclosure(prompt: item.postProcessingPrompt)
                MonospacedCopyBlock(text: item.postProcessedTranscript.isEmpty
                    ? "(empty transcript)" : item.postProcessedTranscript,
                    emptyText: item.postProcessedTranscript.isEmpty,
                    copyTooltip: "Copy cleaned transcript",
                    copiedTooltip: "Copied cleaned transcript")
            }
        }
    }

    private var vocabularyTerms: [String] {
        item.customVocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct PromptDisclosure: View {
    let prompt: String?
    @State private var isShown = false

    var body: some View {
        Group {
            if let prompt, !prompt.isEmpty {
                Button {
                    isShown.toggle()
                } label: {
                    Label(isShown ? "Hide Prompt" : "Show Prompt",
                          systemImage: isShown ? "chevron.down" : "chevron.right")
                }
                .font(.caption)
                if isShown {
                    ScrollView {
                        Text(prompt)
                            .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                }
            }
        }
    }
}

private struct MonospacedCopyBlock: View {
    let text: String
    let emptyText: Bool
    let copyTooltip: String
    let copiedTooltip: String

    @State private var copied = false
    @State private var resetWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                Text(text)
                    .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                copied = true
                resetWorkItem?.cancel()
                let workItem = DispatchWorkItem { copied = false }
                resetWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(copied ? .green : .secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help(copied ? copiedTooltip : copyTooltip)
        }
    }
}

struct PipelineStepView<Content: View>: View {
    let stepNumber: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text("\(stepNumber)")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                    )
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
    }
}

// MARK: - Audio player

final class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinished()
    }
}

struct AudioPlayerView: View {
    let audioURL: URL

    @State private var player: AVAudioPlayer?
    @State private var delegateHolder: DelegateHolder?
    @State private var isPlaying = false
    @State private var elapsed: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isUnreadable = false
    @State private var progressTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    struct DelegateHolder {
        let delegate: AudioPlayerDelegate
    }

    var body: some View {
        Group {
            if isUnreadable {
                Label("Audio file is missing or unreadable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                playerControls
            }
        }
        .onAppear {
            // Deleted or truncated history files should surface as an error,
            // not as a silent dead play button.
            isUnreadable = !FileManager.default.fileExists(atPath: audioURL.path)
        }
    }

    private var playerControls: some View {
        HStack(spacing: 10) {
            Button {
                isPlaying ? stop() : play()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * progressFraction)
                }
            }
            .frame(height: 4)
            Text("\(timeString(elapsed)) / \(timeString(duration))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .onReceive(progressTimer) { _ in
            guard isPlaying, let player else { return }
            elapsed = player.currentTime
        }
        .onDisappear {
            stop()
        }
    }

    private var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1)
    }

    private func timeString(_ value: TimeInterval) -> String {
        let total = Int(value)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func play() {
        stop()
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            let holder = DelegateHolder(delegate: AudioPlayerDelegate { [weak audioPlayer] in
                Task { @MainActor in
                    isPlaying = false
                    elapsed = audioPlayer?.duration ?? 0
                }
            })
            audioPlayer.delegate = holder.delegate
            audioPlayer.play()
            player = audioPlayer
            delegateHolder = holder
            duration = audioPlayer.duration
            elapsed = 0
            isPlaying = true
        } catch {
            isUnreadable = true
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Debug

struct DebugSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Debug")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsCard(title: "Overlay", icon: "wrench.and.screwdriver") {
                    Text("Show the recording overlay with simulated audio levels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(appState.isDebugOverlayActive ? "Stop Debug Overlay" : "Debug Overlay") {
                            appState.toggleDebugOverlay()
                        }
                        Spacer()
                    }
                }
                SettingsCard(title: "Update Overlay", icon: "arrow.down.circle") {
                    Toggle("Show after dictation", isOn: $appState.debugShowsUpdateReminderAfterDictation)
                    HStack {
                        Button("Show Update Overlay Now") {
                            appState.showDebugUpdateAvailableOverlay()
                        }
                        Spacer()
                    }
                }
            }
            .padding(24)
        }
    }
}
