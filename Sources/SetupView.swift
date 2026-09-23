import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import Combine

// MARK: - GitHub metadata cache

struct GitHubRepoInfo: Decodable {
    let stargazersCount: Int

    enum CodingKeys: String, CodingKey {
        case stargazersCount = "stargazers_count"
    }
}

struct GitHubStarUser: Decodable, Identifiable {
    let id: Int
    let login: String
    let avatarUrl: String
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case id
        case login
        case avatarUrl = "avatar_url"
        case htmlUrl = "html_url"
    }

    var avatarThumbnailUrl: String {
        "\(avatarUrl)?s=44"
    }
}

struct GitHubStarRecord: Decodable, Identifiable {
    let starredAt: String
    let user: GitHubStarUser

    var id: Int { user.id }

    enum CodingKeys: String, CodingKey {
        case starredAt = "starred_at"
        case user
    }
}

struct GitHubContributor: Decodable, Identifiable {
    let id: Int
    let login: String
    let avatarUrl: String
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case id
        case login
        case avatarUrl = "avatar_url"
        case htmlUrl = "html_url"
    }

    var avatarThumbnailUrl: String {
        "\(avatarUrl)?s=44"
    }
}

@MainActor
final class GitHubMetadataCache: ObservableObject {
    static let shared = GitHubMetadataCache()

    @Published var starCount: Int?
    @Published var recentStargazers: [GitHubStarRecord] = []
    @Published var recentContributors: [GitHubContributor] = []
    @Published var isLoading = true

    private var lastFetchedAt: Date?
    private let cacheDuration: TimeInterval = 5 * 60

    private init() {}

    func fetchIfNeeded() async {
        if let lastFetchedAt, Date().timeIntervalSince(lastFetchedAt) < cacheDuration {
            return
        }
        isLoading = true
        defer { isLoading = false }
        var fetchedAnything = false

        if let repoInfo = await fetchJSON(GitHubRepoInfo.self,
                                          urlString: "https://api.github.com/repos/nick8cyber/OmniFlow") {
            starCount = repoInfo.stargazersCount
            fetchedAnything = true
        }

        if let repo = URL(string: "https://api.github.com/repos/nick8cyber/OmniFlow/stargazers"),
           var components = URLComponents(url: repo, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "per_page", value: "100"),
                                     URLQueryItem(name: "page", value: "1")]
            var request = URLRequest(url: components.url!)
            request.setValue("application/vnd.github.v3.star+json", forHTTPHeaderField: "Accept")
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let records = try? JSONDecoder().decode([GitHubStarRecord].self, from: data) {
                recentStargazers = Array(records.reversed().prefix(15))
                fetchedAnything = true
            }
        }

        if let contributors = await fetchJSON([GitHubContributor].self,
                                              urlString: "https://api.github.com/repos/nick8cyber/OmniFlow/contributors?per_page=15") {
            recentContributors = Array(contributors.prefix(15))
            fetchedAnything = true
        }

        if fetchedAnything {
            lastFetchedAt = Date()
        }
    }

    private func fetchJSON<T: Decodable>(_ type: T.Type, urlString: String) async -> T? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Standalone row view: extracting it from ForEach avoids a SwiftUI
/// type-checker blowup with AsyncImage(url:) overload resolution.
struct GitHubAvatarView: View {
    let avatarURL: String
    let profileURL: String

    var body: some View {
        AsyncImage(url: URL(string: avatarURL)) { image in
            image.resizable()
                .frame(width: 22, height: 22)
                .clipShape(Circle())
        } placeholder: {
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 22, height: 22)
        }
        .onTapGesture {
            if let url = URL(string: profileURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Overlay style components (shared with Settings)

struct OverlayStyleOptionRow: View {
    let isMinimalist: Bool
    @Binding var selection: Bool

    private var isSelected: Bool {
        selection == isMinimalist
    }

    var body: some View {
        Button {
            selection = isMinimalist
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .blue : .secondary)
                OverlayStylePreview(isMinimalist: isMinimalist)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isMinimalist ? "Minimalist menu-bar overlay" : "Drop-down pill")
                        .font(.headline)
                    Text(isMinimalist
                        ? "Two slim wings flank the camera notch and stay inside the menu bar. Never covers app tabs or toolbars."
                        : "Single pill hangs below the menu bar during recording. Larger and more visible, but covers a thin strip of whatever app is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

struct OverlayStylePreview: View {
    let isMinimalist: Bool

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 110, height: 56)
            VStack(spacing: 3) {
                ZStack(alignment: .center) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 8)
                    HStack(spacing: 0) {
                        if isMinimalist {
                            MinimalistWingShape()
                                .fill(Color.black)
                                .frame(width: 16, height: 8)
                        }
                        Rectangle()
                            .fill(Color.black)
                            .frame(width: 26, height: 8)
                        if isMinimalist {
                            MinimalistWingShape(mirrored: true)
                                .fill(Color.black)
                                .frame(width: 16, height: 8)
                        }
                    }
                }
                .frame(height: 8)
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(0.14))
                            .frame(width: 14, height: 6)
                    }
                }
                Spacer()
            }
            .padding(.top, 0)
            if !isMinimalist {
                UnevenCapsule()
                    .fill(Color.black)
                    .frame(width: 36, height: 20)
                    .offset(y: 8)
            }
        }
        .frame(width: 110, height: 56)
        .clipped()
    }
}

private struct MinimalistWingShape: Shape {
    var mirrored = false

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 3
        var path = Path()
        if mirrored {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

private struct UnevenCapsule: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: 5, style: .continuous)
    }
}

// MARK: - Setup helpers

struct HowToRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct InlineTranscribingDots: View {
    @State private var activeDot = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.blue.opacity(index == activeDot ? 1.0 : 0.3))
                    .frame(width: 12, height: 12)
                    .scaleEffect(index == activeDot ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: activeDot)
            }
        }
        .onReceive(timer) { _ in
            activeDot = (activeDot + 1) % 3
        }
    }
}

// MARK: - SetupView

struct SetupView: View {
    private enum SetupStep: Int, CaseIterable {
        case welcome, apiKey, micPermission, accessibility, screenRecording
        case holdShortcut, toggleShortcut, copyAgainShortcut, commandMode
        case vocabulary, launchAtLogin, overlayStyle, testTranscription, ready
    }

    private enum TestPhase {
        case idle, recording, transcribing, done
    }

    let onComplete: () -> Void

    @EnvironmentObject private var appState: AppState
    @StateObject private var githubCache = GitHubMetadataCache.shared
    @StateObject private var testHotkeyHarness = SetupTestHotkeyHarness()

    @State private var currentStep: SetupStep = .welcome
    @State private var apiKeyInput = ""
    @State private var isValidatingKey = false
    @State private var keyValidationError: String?
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var capturingHold = false
    @State private var capturingToggle = false
    @State private var capturingCopyAgain = false
    @State private var holdValidationMessage: String?
    @State private var toggleValidationMessage: String?
    @State private var copyAgainValidationMessage: String?
    @State private var commandModeEnabled = false
    @State private var commandModeStyleChoice: CommandModeStyle = .automatic
    @State private var commandModeManualModifierChoice: CommandModeManualModifier = .command
    @State private var customVocabularyDraft = ""
    @State private var accessibilityPollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    @State private var screenPollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    @State private var testPhase: TestPhase = .idle
    @State private var testTranscript = ""
    @State private var testError: String?
    @State private var testAudioLevel: Float = 0
    @State private var testRecorder: AudioRecorder?
    @State private var testLevelCancellable: AnyCancellable?
    @State private var testMicPulsing = false
    @State private var screenRecordingGranted = false

    @AppStorage("use_compact_overlay") private var useCompactOverlay = true

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 16)
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.vertical, 32)
            Divider()
            footer
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear(perform: initialize)
        .onDisappear {
            accessibilityPollTimer.upstream.connect().cancel()
            screenPollTimer.upstream.connect().cancel()
            appState.resumeHotkeyMonitoringAfterShortcutCapture()
            stopTest()
        }
        .onChange(of: capturingHold) { capturing in
            captureStateChanged(capturing || capturingToggle || capturingCopyAgain)
        }
        .onChange(of: capturingToggle) { capturing in
            captureStateChanged(capturing || capturingHold || capturingCopyAgain)
        }
        .onChange(of: capturingCopyAgain) { capturing in
            captureStateChanged(capturing || capturingHold || capturingToggle)
        }
        .onReceive(accessibilityPollTimer) { _ in
            guard currentStep == .accessibility else { return }
            accessibilityGranted = AXIsProcessTrusted()
        }
        .onReceive(screenPollTimer) { _ in
            guard currentStep == .screenRecording else { return }
            screenRecordingGranted = appState.hasScreenCapturePermission()
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step == currentStep ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .apiKey:
            apiKeyStep
        case .micPermission:
            permissionStep(icon: "mic.fill",
                           title: "Microphone Access",
                           bodyText: "\(AppName.displayName) needs microphone access to transcribe your speech.")
        case .accessibility:
            permissionStep(icon: "hand.raised.fill",
                           title: "Accessibility Access",
                           bodyText: "Accessibility lets \(AppName.displayName) paste text at your cursor position.")
        case .screenRecording:
            screenRecordingStep
        case .holdShortcut:
            shortcutStep(icon: "keyboard.fill", title: "Hold to Talk Shortcut", role: .hold,
                         extraAdvice: AnyView(fnAdvice))
        case .toggleShortcut:
            shortcutStep(icon: "switch.2", title: "Tap to Toggle Shortcut", role: .toggle,
                         extraAdvice: AnyView(VStack(alignment: .leading, spacing: 6) {
                             fnAdvice
                             Text("Activating the toggle shortcut while holding latches dictation into tap mode.")
                                 .font(.caption)
                                 .foregroundStyle(.secondary)
                         }))
        case .copyAgainShortcut:
            shortcutStep(icon: "doc.on.clipboard", title: "Paste Again Shortcut", role: .copyAgain,
                         introText: "Optional. Repeats your last transcript at the cursor without recording again.",
                         extraAdvice: AnyView(fnAdvice))
        case .commandMode:
            commandModeStep
        case .vocabulary:
            vocabularyStep
        case .launchAtLogin:
            launchAtLoginStep
        case .overlayStyle:
            overlayStyleStep
        case .testTranscription:
            testTranscriptionStep
        case .ready:
            readyStep
        }
    }

    private func initialize() {
        apiKeyInput = appState.apiKey
        customVocabularyDraft = appState.customVocabulary
        commandModeEnabled = appState.isCommandModeEnabled
        commandModeStyleChoice = appState.commandModeStyle
        commandModeManualModifierChoice = appState.commandModeManualModifier
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        Task { await githubCache.fetchIfNeeded() }
    }

    private func captureStateChanged(_ capturing: Bool) {
        if capturing {
            appState.suspendHotkeyMonitoringForShortcutCapture()
        } else {
            appState.resumeHotkeyMonitoringAfterShortcutCapture()
        }
    }

    private var fnAdvice: some View {
        Label("If pressing your shortcut opens the emoji picker instead, set the Globe/Fn key to \"Do Nothing\" in System Settings > Keyboard > Keyboard Shortcuts > Fn Keys.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(.orange)
    }

    // welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("Welcome to \(AppName.displayName)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Dictate text anywhere on your Mac.\nHold to talk or tap to toggle dictation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
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
                            Text("\(starCount.formatted()) stars").font(.caption)
                        }
                    }
                }
                if !githubCache.recentContributors.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(githubCache.recentContributors.prefix(15)) { contributor in
                            AsyncImage(url: URL(string: contributor.avatarThumbnailUrl)) { image in
                                image.resizable().frame(width: 22, height: 22).clipShape(Circle())
                            } placeholder: {
                                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 22, height: 22)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            Spacer()
        }
        .padding(.top, 24)
    }

    // api key

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("API Key")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("Using Groq?")
                    .font(.headline)
                Label("Open console.groq.com/keys in your browser.", systemImage: "1.circle")
                    .font(.caption)
                Label("Sign in or create a free account.", systemImage: "2.circle")
                    .font(.caption)
                Label("Create an API key and paste it below.", systemImage: "3.circle")
                    .font(.caption)
            }
            SecureField("Paste your API key", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                .onChange(of: apiKeyInput) { _ in
                    keyValidationError = nil
                }
            if let keyValidationError {
                Text(keyValidationError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            Button {
                showsProviderSheet = true
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced Provider Settings")
                            .font(.callout.weight(.semibold))
                        Text("Base URL and model IDs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .sheet(isPresented: $showsProviderSheet) {
            SetupProviderSettingsSheet()
        }
    }

    @State private var showsProviderSheet = false

    // permissions

    private func permissionStep(icon: String, title: String, bodyText: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text(title)
                .font(.largeTitle.bold())
            Text(bodyText)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: grantedForCurrentStep ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(grantedForCurrentStep ? .green : .secondary)
                Text(title)
                Spacer()
                if grantedForCurrentStep {
                    Text("Granted")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Button("Grant Access") {
                        requestPermissionForCurrentStep()
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            Spacer()
        }
    }

    private var grantedForCurrentStep: Bool {
        switch currentStep {
        case .micPermission: return micPermissionGranted
        case .accessibility: return accessibilityGranted
        default: return appState.hasScreenRecordingPermission
        }
    }

    private func requestPermissionForCurrentStep() {
        switch currentStep {
        case .micPermission:
            appState.requestMicrophoneAccess { granted in
                micPermissionGranted = granted
            }
        case .accessibility:
            appState.openAccessibilitySettings()
        default:
            break
        }
    }

    private var screenRecordingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("Screen Recording")
                .font(.largeTitle.bold())
            Text("Edit Mode reads the text you have selected so the model can transform it inside your app.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Nothing is stored on any server — the selection is sent only to the model provider you configure.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: screenRecordingGranted ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(screenRecordingGranted ? .green : .secondary)
                Text("Screen Recording")
                Spacer()
                if screenRecordingGranted {
                    Text("Granted")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Button("Grant Access") {
                        appState.requestScreenCapturePermission()
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            Spacer()
        }
    }

    // shortcuts

    private func shortcutStep(icon: String, title: String, role: ShortcutRole,
                              introText: String? = nil, extraAdvice: AnyView? = nil) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.blue)
            Text(title)
                .font(.largeTitle.bold())
            if let introText {
                Text(introText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ShortcutRoleSection(role: role,
                                selection: selectionForRole(role),
                                savedBinding: appState.savedCustomShortcut(for: role),
                                validationMessage: validationForRole(role),
                                isCapturing: bindingForRole(role),
                                onSelect: { select($0, for: role) },
                                onCaptureStateChange: nil)
            if let extraAdvice {
                extraAdvice
            }
            Spacer()
        }
    }

    private func selectionForRole(_ role: ShortcutRole) -> ShortcutBinding {
        switch role {
        case .hold: return appState.holdShortcut
        case .toggle: return appState.toggleShortcut
        case .copyAgain: return appState.copyAgainShortcut
        }
    }

    private func validationForRole(_ role: ShortcutRole) -> String? {
        switch role {
        case .hold: return holdValidationMessage
        case .toggle: return toggleValidationMessage
        case .copyAgain: return copyAgainValidationMessage
        }
    }

    private func bindingForRole(_ role: ShortcutRole) -> Binding<Bool> {
        switch role {
        case .hold: return $capturingHold
        case .toggle: return $capturingToggle
        case .copyAgain: return $capturingCopyAgain
        }
    }

    private func select(_ binding: ShortcutBinding, for role: ShortcutRole) {
        let message = appState.setShortcut(binding, for: role)
        switch role {
        case .hold: holdValidationMessage = message
        case .toggle: toggleValidationMessage = message
        case .copyAgain: copyAgainValidationMessage = message
        }
    }

    // command mode

    private var commandModeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "pencil")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            Text("Edit Mode")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable Edit Mode", isOn: Binding(
                    get: { commandModeEnabled },
                    set: { newValue in
                        commandModeEnabled = newValue
                        _ = appState.setCommandModeEnabled(newValue)
                    }))
                Text("Transform highlighted text with a spoken instruction instead of dictating over it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Invocation Style", selection: Binding(
                    get: { commandModeStyleChoice },
                    set: { newValue in
                        commandModeStyleChoice = newValue
                        _ = appState.setCommandModeStyle(newValue)
                    })) {
                    Text("Automatic").tag(CommandModeStyle.automatic)
                    Text("Manual").tag(CommandModeStyle.manual)
                }
                .pickerStyle(.segmented)
                .disabled(!commandModeEnabled)
                if commandModeStyleChoice == .manual {
                    Picker("Extra Modifier", selection: Binding(
                        get: { commandModeManualModifierChoice },
                        set: { newValue in
                            commandModeManualModifierChoice = newValue
                            _ = appState.setCommandModeManualModifier(newValue)
                        })) {
                        Text("Cmd ⌘").tag(CommandModeManualModifier.command)
                        Text("Ctrl ⌃").tag(CommandModeManualModifier.control)
                        Text("Option ⌥").tag(CommandModeManualModifier.option)
                        Text("Shift ⇧").tag(CommandModeManualModifier.shift)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!commandModeEnabled)
                }
                if let message = appState.commandModeManualModifierValidationMessage {
                    Label(message, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            Spacer()
        }
    }

    // vocabulary

    private var vocabularyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            Text("Custom Vocabulary")
                .font(.largeTitle.bold())
            Text("Names, jargon, and spellings the model should prefer.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $customVocabularyDraft)
                .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                .frame(minHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            Spacer()
        }
    }

    private func saveCustomVocabularyAndContinue() {
        appState.customVocabulary = customVocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        advance()
    }

    // launch at login

    private var launchAtLoginStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sunrise.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            Text("Launch at Login")
                .font(.largeTitle.bold())
            Toggle("Launch \(AppName.displayName) at login", isOn: $appState.launchAtLogin)
            Spacer()
        }
    }

    // overlay style

    private var overlayStyleStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            Text("Recording overlay style")
                .font(.largeTitle.bold())
            VStack(spacing: 8) {
                OverlayStyleOptionRow(isMinimalist: true, selection: $useCompactOverlay)
                OverlayStyleOptionRow(isMinimalist: false, selection: $useCompactOverlay)
            }
            Text("You can change this later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // test transcription

    private var testShortcutPrompt: String {
        let holdName = appState.holdShortcut.isDisabled ? nil : appState.holdShortcut.displayName
        let toggleName = appState.toggleShortcut.isDisabled ? nil : appState.toggleShortcut.displayName
        switch (holdName, toggleName) {
        case let (hold?, toggle?):
            return "Hold \(hold) or tap \(toggle)"
        case let (hold?, nil):
            return "Hold \(hold)"
        case let (nil, toggle?):
            return "Tap \(toggle)"
        default:
            return "Use Start Dictating from the menu bar"
        }
    }

    private var retryShortcutPrompt: String {
        "\(testShortcutPrompt) to try again"
    }

    private var testTranscriptionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Microphone:", selection: $appState.selectedMicrophoneID) {
                Text("System Default").tag("default")
                ForEach(appState.availableMicrophones) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 340)
            Text("You can change this later in the menu bar or settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            testPhaseContent
                .frame(maxWidth: .infinity)
            Spacer()
        }
        .onAppear {
            appState.refreshAvailableMicrophones()
            configureTestHarness()
            DispatchQueue.main.async {
                testMicPulsing = true
            }
        }
    }

    @ViewBuilder
    private var testPhaseContent: some View {
        switch testPhase {
        case .idle:
            VStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                    .scaleEffect(testMicPulsing ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: testMicPulsing)
                Text("Let's Try It Out!")
                    .font(.title2.bold())
                Text(testShortcutPrompt)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.blue.opacity(0.12)))
                    .foregroundColor(.blue)
                Text("Say anything — a sentence or two is perfect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .recording:
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.65))
                        .frame(width: 100, height: 100)
                        .overlay(Circle().stroke(Color.blue.opacity(0.8), lineWidth: 3))
                        .shadow(color: .blue.opacity(0.8), radius: 10)
                    WaveformView(audioLevel: testAudioLevel)
                }
                Text("Listening...")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.blue)
            }
        case .transcribing:
            VStack(spacing: 12) {
                InlineTranscribingDots()
                Text("Transcribing...")
                    .font(.title2.weight(.semibold))
            }
        case .done:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
                if let testError {
                    Text("Something went wrong")
                        .font(.title2.weight(.semibold))
                    Text(testError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                } else if testTranscript.isEmpty {
                    Text("No speech detected")
                        .font(.title2.weight(.semibold))
                } else {
                    Text("Perfect — \(AppName.displayName) is ready to go.")
                        .font(.title2.weight(.semibold))
                    Text(testTranscript)
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: 420)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Text(retryShortcutPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func configureTestHarness() {
        testHotkeyHarness.isTranscribing = false
        testHotkeyHarness.onAction = { action in
            handleTestAction(action)
        }
        let configuration = ShortcutConfiguration(hold: appState.holdShortcut,
                                                  toggle: appState.toggleShortcut)
        try? testHotkeyHarness.start(configuration: configuration,
                                     startDelay: appState.shortcutStartDelay)
    }

    private func handleTestAction(_ action: DictationShortcutAction) {
        switch action {
        case .start:
            guard testPhase == .idle || testPhase == .done else { return }
            if testPhase == .done {
                resetTest()
            }
            startTestRecording()
        case .stop:
            guard testPhase == .recording else { return }
            stopTestRecordingAndTranscribe()
        case .switchedToToggle:
            break
        }
    }

    private func startTestRecording() {
        let recorder = AudioRecorder()
        do {
            try recorder.startRecording(deviceUID: appState.selectedMicrophoneID)
        } catch {
            testError = error.localizedDescription
            testPhase = .done
            return
        }
        testRecorder = recorder
        testLevelCancellable = recorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { level in
                testAudioLevel = level
            }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            testPhase = .recording
        }
    }

    private func stopTestRecordingAndTranscribe() {
        guard let recorder = testRecorder else { return }
        testAudioLevel = 0
        testHotkeyHarness.isTranscribing = true
        testPhase = .transcribing
        recorder.stopRecording { url in
            DispatchQueue.main.async {
                guard let url else {
                    testError = "No audio file was created."
                    testPhase = .done
                    testHotkeyHarness.isTranscribing = false
                    recorder.cleanup()
                    return
                }
                Task {
                    do {
                        let service = try appState.makeTranscriptionService()
                        let transcript = try await service.transcribe(fileURL: url)
                        testTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        testError = nil
                    } catch {
                        testError = error.localizedDescription
                    }
                    testHotkeyHarness.isTranscribing = false
                    recorder.cleanup()
                    testPhase = .done
                }
            }
        }
    }

    private func resetTest() {
        testTranscript = ""
        testError = nil
        testAudioLevel = 0
        testPhase = .idle
    }

    private func stopTest() {
        testHotkeyHarness.stop()
        testLevelCancellable?.cancel()
        testLevelCancellable = nil
        testRecorder?.cancelRecording()
        testRecorder?.cleanup()
        testRecorder = nil
    }

    // ready

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            Text("You're All Set!")
                .font(.largeTitle.bold())
            Text("\(AppName.displayName) lives in your menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                if appState.hasEnabledHoldShortcut {
                    HowToRow(icon: "keyboard",
                             text: "Hold \(appState.holdShortcut.displayName) to record")
                }
                if appState.hasEnabledToggleShortcut {
                    HowToRow(icon: "switch.2",
                             text: "Tap \(appState.toggleShortcut.displayName) to start and stop")
                }
                if appState.hasEnabledHoldShortcut && appState.hasEnabledToggleShortcut {
                    HowToRow(icon: "arrow.triangle.branch",
                             text: "While holding, press the toggle shortcut to latch on")
                }
                if appState.isCommandModeEnabled {
                    if appState.commandModeStyle == .automatic {
                        HowToRow(icon: "wand.and.stars",
                                 text: "With text selected, your normal shortcut transforms the selection")
                    } else {
                        HowToRow(icon: "wand.and.stars",
                                 text: "Hold \(appState.commandModeManualModifier.title) with your normal shortcut to transform selected text")
                    }
                }
                HowToRow(icon: "doc.on.clipboard",
                         text: "Text is typed at your cursor & copied")
            }
            Spacer()
        }
    }

    // MARK: Footer

    private var canContinueFromCurrentStep: Bool {
        switch currentStep {
        case .micPermission:
            return micPermissionGranted
        case .accessibility:
            return accessibilityGranted
        case .screenRecording:
            return appState.hasScreenRecordingPermission
        case .testTranscription:
            return testPhase == .done && !testTranscript.isEmpty && testError == nil
        default:
            return true
        }
    }

    private var footer: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    keyValidationError = nil
                    withAnimation {
                        currentStep = SetupStep(rawValue: max(currentStep.rawValue - 1, 0)) ?? .welcome
                    }
                }
                .disabled(isValidatingKey)
            }
            Spacer()
            switch currentStep {
            case .apiKey:
                Button(isValidatingKey ? "Validating..." : "Continue") {
                    validateAndContinue()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)
            case .vocabulary:
                Button("Continue") {
                    saveCustomVocabularyAndContinue()
                }
                .keyboardShortcut(.defaultAction)
            case .testTranscription:
                Button("Skip") {
                    testHotkeyHarness.stop()
                    advance()
                }
                .buttonStyle(.plain)
                Button("Continue") {
                    advance()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(testPhase != .done || testTranscript.isEmpty || testError != nil)
            case .ready:
                Button("Get Started") {
                    onComplete()
                }
                .keyboardShortcut(.defaultAction)
            default:
                Button("Continue") {
                    advance()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinueFromCurrentStep)
            }
        }
    }

    private func advance() {
        withAnimation {
            if let next = SetupStep(rawValue: currentStep.rawValue + 1) {
                currentStep = next
            }
        }
    }

    private func validateAndContinue() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isValidatingKey = true
        keyValidationError = nil
        let baseURL = appState.apiBaseURL.isEmpty ? AppState.defaultAPIBaseURL : appState.apiBaseURL
        appState.apiBaseURL = baseURL
        Task {
            let valid = await TranscriptionService.validateAPIKey(key, baseURL: baseURL)
            await MainActor.run {
                isValidatingKey = false
                if valid {
                    appState.apiKey = key
                    advance()
                } else {
                    keyValidationError = "Validation failed. Please check your API key and provider settings, then try again."
                }
            }
        }
    }
}

// MARK: - Provider settings sheet

private struct SetupProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Advanced Provider Settings")
                .font(.headline)
            ScrollView {
                ProviderSettingsFields(showsModelDescription: true)
            }
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}
