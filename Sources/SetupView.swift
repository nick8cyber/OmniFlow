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
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let records = try? JSONDecoder().decode([GitHubStarRecord].self, from: data) {
                var newestRecords = records
                // Page 1 holds the oldest stargazers; the newest ones live on
                // the last page, so follow the Link header when paginated.
                let lastPage = Self.lastStargazersPage(from: response)
                if lastPage > 1,
                   let lastURL = Self.stargazersURL(repo: repo, page: lastPage) {
                    var lastRequest = URLRequest(url: lastURL)
                    lastRequest.setValue("application/vnd.github.v3.star+json",
                                         forHTTPHeaderField: "Accept")
                    if let (lastData, _) = try? await URLSession.shared.data(for: lastRequest),
                       let lastRecords = try? JSONDecoder().decode([GitHubStarRecord].self, from: lastData),
                       !lastRecords.isEmpty {
                        newestRecords = lastRecords
                    }
                }
                recentStargazers = Array(newestRecords.reversed().prefix(15))
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

    /// GitHub paginates with a `Link` header; `rel="last"` points at the final
    /// page (`...?per_page=100&page=N`). Returns 1 when the header is absent
    /// (single page).
    private static func lastStargazersPage(from response: URLResponse) -> Int {
        guard let httpResponse = response as? HTTPURLResponse,
              let link = httpResponse.value(forHTTPHeaderField: "Link") else { return 1 }
        for segment in link.components(separatedBy: ",") {
            guard segment.contains(#"rel="last""#),
                  let range = segment.range(of: #"[?&]page=(\d+)"#, options: .regularExpression) else {
                continue
            }
            let match = segment[range]
            if let number = Int(match.drop(while: { $0 != "=" }).dropFirst()) {
                return number
            }
        }
        return 1
    }

    private static func stargazersURL(repo: URL, page: Int) -> URL? {
        guard var components = URLComponents(url: repo, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: "100"),
                                 URLQueryItem(name: "page", value: String(page))]
        return components.url
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

// MARK: - Setup helpers

struct HowToRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
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
                    .fill(Color.accentColor.opacity(index == activeDot ? 1.0 : 0.3))
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
        case welcome, provider, permissions, shortcuts, personalize, testTranscription, ready
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
    @State private var keyValidationDetail: String?
    @State private var providerUnreachable = false
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenRecordingGranted = false
    @State private var customVocabularyDraft = ""
    @State private var permissionsPollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    @State private var testPhase: TestPhase = .idle
    @State private var testTranscript = ""
    @State private var testError: String?
    @State private var testAudioLevel: Float = 0
    @State private var testRecorder: AudioRecorder?
    @State private var testLevelCancellable: AnyCancellable?
    @State private var testMicPulsing = false

    @AppStorage("overlay_display_id") private var overlayDisplayID = 0

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
            permissionsPollTimer.upstream.connect().cancel()
            appState.resumeHotkeyMonitoringAfterShortcutCapture()
            stopTest()
        }
        .onReceive(permissionsPollTimer) { _ in
            guard currentStep == .permissions else { return }
            // React to permissions granted later in System Settings: the row
            // states and the Continue gate must read the same live state.
            micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            accessibilityGranted = AXIsProcessTrusted()
            let granted = appState.hasScreenCapturePermission()
            screenRecordingGranted = granted
            if appState.hasScreenRecordingPermission != granted {
                appState.hasScreenRecordingPermission = granted
            }
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step == currentStep ? Color.accentColor : Color.gray.opacity(0.3))
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
        case .provider:
            providerStep
        case .permissions:
            permissionsStep
        case .shortcuts:
            shortcutsStep
        case .personalize:
            personalizeStep
        case .testTranscription:
            testTranscriptionStep
        case .ready:
            readyStep
        }
    }

    private func initialize() {
        apiKeyInput = appState.apiKey
        customVocabularyDraft = appState.customVocabulary
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = appState.hasScreenCapturePermission()
        Task { await githubCache.fetchIfNeeded() }
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
                            GitHubAvatarView(avatarURL: contributor.avatarUrl + "?s=44",
                                             profileURL: contributor.htmlUrl)
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

    // provider

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Choose Provider")
                .font(.largeTitle.bold())
            Text("Pick the API family your key belongs to — the fields adapt. Gemini handles transcription and cleanup with one key; OpenAI-compatible providers run a separate cleanup model.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ProviderCardPair(selection: Binding(
                get: { appState.aiProvider },
                set: { appState.setAIProvider($0) }))
            HStack(spacing: 8) {
                SecureField(appState.aiProvider == .gemini ? "Paste your Gemini API key" : "Paste your API key",
                            text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                    .onChange(of: apiKeyInput) { _ in
                        keyValidationError = nil
                        keyValidationDetail = nil
                        providerUnreachable = false
                    }
                if appState.aiProvider == .gemini {
                    Text("aistudio.google.com → Get API key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let keyValidationError {
                Text(keyValidationError)
                    .font(.caption)
                    .foregroundColor(providerUnreachable ? .orange : .red)
            }
            if providerUnreachable, let keyValidationDetail {
                Text(keyValidationDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .sheet(isPresented: $showsProviderSheet) {
            SetupProviderSettingsSheet()
        }
    }

    @State private var showsProviderSheet = false

    // permissions (was three separate steps)

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "shield")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Permissions")
                .font(.largeTitle.bold())
            Text("Microphone records you, Accessibility pastes at the cursor, Screen Recording lets Edit Mode read the selected text. Nothing is stored on any server — audio and screenshots go only to the provider you configure.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                permissionRow(icon: "mic.fill",
                              title: "Microphone",
                              granted: micPermissionGranted) {
                    appState.requestMicrophoneAccess { granted in
                        micPermissionGranted = granted
                    }
                }
                Divider().padding(.horizontal, 12)
                permissionRow(icon: "hand.raised.fill",
                              title: "Accessibility",
                              granted: accessibilityGranted) {
                    appState.openAccessibilitySettings()
                }
                Divider().padding(.horizontal, 12)
                permissionRow(icon: "camera.viewfinder",
                              title: "Screen Recording",
                              granted: screenRecordingGranted) {
                    appState.requestScreenCapturePermission()
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            Spacer()
        }
    }

    private func permissionRow(icon: String, title: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
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
        .padding(12)
    }

    // shortcuts (was three separate steps)

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Shortcuts")
                .font(.largeTitle.bold())
            Text("All three roles on one screen. Hold to record, tap to start and stop, press the toggle shortcut while holding to latch into tap mode.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                DictationShortcutEditor(onCaptureStateChange: { capturing in
                    if capturing {
                        appState.suspendHotkeyMonitoringForShortcutCapture()
                    } else {
                        appState.resumeHotkeyMonitoringAfterShortcutCapture()
                    }
                })
            }
            Spacer()
        }
    }

    // personalize (was four separate steps)

    private var personalizeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Personalize")
                .font(.largeTitle.bold())
            Text("Everything here is optional — you can change it later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    SettingsCard(title: "Edit Mode", icon: "pencil",
                                 subtitle: "Transform highlighted text with a spoken instruction") {
                        VStack(spacing: 10) {
                            FormRow(title: "Enable Edit Mode") {
                                Toggle("", isOn: Binding(
                                    get: { appState.isCommandModeEnabled },
                                    set: { _ = appState.setCommandModeEnabled($0) }))
                                    .toggleStyle(.switch)
                            }
                            Picker("Invocation Style", selection: Binding(
                                get: { appState.commandModeStyle },
                                set: { _ = appState.setCommandModeStyle($0) })) {
                                Text("Automatic").tag(CommandModeStyle.automatic)
                                Text("Manual").tag(CommandModeStyle.manual)
                            }
                            .pickerStyle(.segmented)
                            .disabled(!appState.isCommandModeEnabled)
                            if appState.commandModeStyle == .manual {
                                Picker("Extra Modifier", selection: Binding(
                                    get: { appState.commandModeManualModifier },
                                    set: { _ = appState.setCommandModeManualModifier($0) })) {
                                    Text("Cmd ⌘").tag(CommandModeManualModifier.command)
                                    Text("Ctrl ⌃").tag(CommandModeManualModifier.control)
                                    Text("Option ⌥").tag(CommandModeManualModifier.option)
                                    Text("Shift ⇧").tag(CommandModeManualModifier.shift)
                                }
                                .pickerStyle(.segmented)
                                .disabled(!appState.isCommandModeEnabled)
                            }
                            if let message = appState.commandModeManualModifierValidationMessage {
                                Label(message, systemImage: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    SettingsCard(title: "Custom Vocabulary", icon: "text.book.closed.fill",
                                 subtitle: "Names, jargon, and spellings the model should prefer") {
                        TextEditor(text: $customVocabularyDraft)
                            .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                            .frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    }
                    SettingsCard(title: "Startup & Overlay", icon: "rectangle.dashed") {
                        VStack(spacing: 10) {
                            FormRow(title: "Launch \(AppName.displayName) at login") {
                                Toggle("", isOn: $appState.launchAtLogin)
                                    .toggleStyle(.switch)
                            }
                            Divider()
                            FormRow(title: "Show overlay on") {
                                Picker("Show on", selection: $overlayDisplayID) {
                                    Text("Active window (default)").tag(0)
                                    Text("Primary display").tag(-1)
                                    ForEach(NSScreen.screens, id: \.self) { screen in
                                        Text(screen.localizedName).tag(Int(screen.displayID))
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 220)
                            }
                        }
                    }
                }
            }
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
                    .foregroundColor(.accentColor)
                    .scaleEffect(testMicPulsing ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: testMicPulsing)
                Text("Let's Try It Out!")
                    .font(.title2.bold())
                Text(testShortcutPrompt)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundColor(.accentColor)
                Text("Say anything — a sentence or two is perfect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .recording:
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: 100, height: 100)
                        .overlay(Circle().stroke(Color.accentColor.opacity(0.8), lineWidth: 3))
                        .shadow(color: Color.accentColor.opacity(0.8), radius: 10)
                    WaveformView(audioLevel: testAudioLevel)
                }
                Text("Listening...")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.accentColor)
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
                            .fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
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
        // Microphone unplug / capture-session failure must end the test
        // immediately instead of leaving "Listening..." on screen forever.
        recorder.onRecordingFailure = { [weak recorder] error in
            guard let recorder else { return }
            Task { @MainActor in
                testLevelCancellable?.cancel()
                testLevelCancellable = nil
                testAudioLevel = 0
                testHotkeyHarness.isTranscribing = false
                testRecorder = nil
                testError = AppState.formattedTranscriptionError(error)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    testPhase = .done
                }
                recorder.cleanup()
            }
        }
        do {
            try recorder.startRecording(deviceUID: appState.selectedMicrophoneID)
        } catch {
            testError = AppState.formattedTranscriptionError(error)
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
                        testError = AppState.formattedTranscriptionError(error)
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

    private var allPermissionsGranted: Bool {
        micPermissionGranted && accessibilityGranted && screenRecordingGranted
    }

    private var footer: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    keyValidationError = nil
                    keyValidationDetail = nil
                    providerUnreachable = false
                    withAnimation {
                        currentStep = SetupStep(rawValue: max(currentStep.rawValue - 1, 0)) ?? .welcome
                    }
                }
                .disabled(isValidatingKey)
            }
            Spacer()
            switch currentStep {
            case .provider:
                if providerUnreachable {
                    Button("Continue Offline") {
                        continueWithoutValidation()
                    }
                }
                Button(isValidatingKey ? "Validating..." : "Continue") {
                    validateAndContinue()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)
            case .personalize:
                Button("Continue") {
                    appState.customVocabulary = customVocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    advance()
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
                .disabled(currentStep == .permissions && !allPermissionsGranted)
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
        keyValidationDetail = nil
        providerUnreachable = false
        let baseURL = appState.aiProvider == .gemini
            ? AIProvider.geminiValidationBaseURL
            : (appState.apiBaseURL.isEmpty ? AppState.defaultAPIBaseURL : appState.apiBaseURL)
        if appState.aiProvider != .gemini {
            appState.apiBaseURL = baseURL
        }
        Task {
            let outcome = await TranscriptionService.validateAPIKey(key, baseURL: baseURL)
            await MainActor.run {
                isValidatingKey = false
                switch outcome {
                case .valid:
                    appState.apiKey = key
                    advance()
                case .invalidKey:
                    keyValidationError = "The provider rejected this API key. Check the key and provider settings, then try again."
                case .unavailable(let detail):
                    providerUnreachable = true
                    keyValidationError = "Provider is unreachable — check your connection."
                    keyValidationDetail = detail
                }
            }
        }
    }

    /// Offered when the provider cannot be reached: saves the entered key and
    /// moves on without validation instead of blocking onboarding.
    private func continueWithoutValidation() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        appState.apiKey = key
        advance()
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
