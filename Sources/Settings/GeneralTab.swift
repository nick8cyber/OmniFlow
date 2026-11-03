import SwiftUI
import AVFoundation
import ServiceManagement

// General tab: app-level behaviour (startup, menu bar, updates), permission
// status, sound feedback, and the About/build block.

struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updateManager = UpdateManager.shared
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true

    @State private var micPermissionGranted = false
    @State private var checkingForUpdates = false
    @State private var volumePreviewHintVisible = false
    @State private var launchAtLoginNeedsApproval = false
    private let micPermissionPollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildTag: String {
        Bundle.main.infoDictionary?["OmniFlowBuildTag"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "unknown"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BrandHeader()
                appCard
                updatesCard
                permissionsCard
                soundCard
                aboutCard
            }
            .padding(20)
        }
        .onAppear(perform: initialize)
        .onReceive(micPermissionPollTimer) { _ in
            // The microphone row needs its own re-check so granting access in
            // System Settings is picked up while the window is open. The
            // accessibility and screen-recording rows follow AppState polling.
            checkMicPermission()
        }
        .onChange(of: appState.alertSoundsEnabled) { _ in
            volumePreviewHintVisible = false
        }
    }

    private func initialize() {
        checkMicPermission()
        appState.refreshLaunchAtLoginStatus()
        launchAtLoginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: App

    private var appCard: some View {
        SettingsCard(title: "App", icon: "power", subtitle: "Startup and menu bar") {
            VStack(spacing: 10) {
                FormRow(title: "Launch \(AppName.displayName) at login") {
                    Toggle("", isOn: $appState.launchAtLogin)
                        .toggleStyle(.switch)
                }
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
                FormRow(title: "Show menu bar icon") {
                    Toggle("", isOn: $showMenuBarIcon)
                        .toggleStyle(.switch)
                }
                if !showMenuBarIcon {
                    Text("Turn it back on in Settings, or relaunch the app to reopen Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                FormRow(title: "Setup wizard",
                        subtitle: "Walks through provider, permissions and shortcuts again") {
                    Button("Re-run…") {
                        NotificationCenter.default.post(name: .showSetup, object: nil)
                    }
                }
            }
        }
    }

    // MARK: Updates

    private var updatesCard: some View {
        SettingsCard(title: "Updates", icon: "arrow.triangle.2.circlepath") {
            VStack(spacing: 10) {
                FormRow(title: "Automatically check for updates") {
                    Toggle("", isOn: Binding(
                        get: { updateManager.autoCheckEnabled },
                        set: { updateManager.autoCheckEnabled = $0 }))
                        .toggleStyle(.switch)
                }
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
    }

    @ViewBuilder
    private var updateStatusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch updateManager.updateStatus {
            case .idle:
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.accentColor)
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
                HStack {
                    Text("Downloading update...")
                    ProgressView(value: updateManager.downloadProgress ?? 0)
                    Text("\(Int((updateManager.downloadProgress ?? 0) * 100))%")
                        .font(.caption)
                    Button("Cancel") {
                        updateManager.cancelDownload()
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
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        SettingsCard(title: "Permissions", icon: "shield", subtitle: "Required for dictation and pasting") {
            VStack(spacing: 12) {
                PermissionStatusRow(icon: "mic.fill",
                                    title: "Microphone",
                                    granted: micPermissionGranted) {
                    appState.requestMicrophoneAccess { granted in
                        micPermissionGranted = granted
                    }
                }
                PermissionStatusRow(icon: "hand.raised.fill",
                                    title: "Accessibility",
                                    granted: appState.hasAccessibility) {
                    appState.openAccessibilitySettings()
                }
                PermissionStatusRow(icon: "camera.viewfinder",
                                    title: "Screen Recording",
                                    granted: appState.hasScreenRecordingPermission) {
                    appState.requestScreenCapturePermission()
                }
            }
        }
    }

    // MARK: Sound

    private var soundCard: some View {
        SettingsCard(title: "Sound", icon: "speaker.wave.2.fill") {
            VStack(spacing: 10) {
                FormRow(title: "Play alert sounds") {
                    Toggle("", isOn: $appState.alertSoundsEnabled)
                        .toggleStyle(.switch)
                }
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .foregroundColor(.secondary)
                    Slider(value: $appState.soundVolume, in: 0...1, step: 0.1)
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.secondary)
                    Text("\(Int(appState.soundVolume * 100))%")
                        .font(.caption)
                        .frame(width: 36, alignment: .trailing)
                    Button("Preview") {
                        let muted = SystemAudioStatus.isDefaultOutputMuted()
                        let volume = SystemAudioStatus.defaultOutputVolume() ?? 0
                        withAnimation(.easeInOut(duration: 0.2)) {
                            volumePreviewHintVisible = muted || volume < 0.10
                        }
                        appState.playAlertSound(named: "Tink")
                    }
                }
                .disabled(!appState.alertSoundsEnabled)
                .opacity(appState.alertSoundsEnabled ? 1 : 0.5)
                if volumePreviewHintVisible {
                    InfoBanner(icon: "speaker.slash.fill",
                               text: "System volume is muted or very low. Unmute to hear the preview.",
                               kind: .warning)
                }
            }
        }
    }

    // MARK: About

    private var aboutCard: some View {
        SettingsCard(title: "About", icon: "info.circle.fill") {
            VStack(spacing: 10) {
                FormRow(title: "Version") {
                    Text("v\(appVersion) (\(buildTag))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Divider()
                AboutDiagnosticsRow(version: appVersion, build: buildTag)
            }
        }
    }
}

private struct AboutDiagnosticsRow: View {
    let version: String
    let build: String

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
            CopyButton(text: diagnostics)
                .font(.caption)
        }
    }
}
