import SwiftUI
import AppKit
import Combine

enum OverlayPhase {
    case initializing, recording, transcribing, feedback, updateAvailable
}

final class RecordingOverlayState: ObservableObject {
    @Published var phase: OverlayPhase = .recording
    @Published var audioLevel: Float = 0.0
    @Published var recordingTriggerMode: RecordingTriggerMode = .hold
    @Published var isCommandMode = false
    @Published var interimTranscript: String = ""
    @Published var statusText: String = ""
    @Published var targetAppName: String = ""
    @Published var updateVersion: String = ""
    @Published var errorMessage: String?
    @Published var toastID: UUID?
}

final class RecordingOverlayManager {
    private static let maxToastMessageLength = 90
    private static let errorToastDuration: TimeInterval = 6.0
    // OverlayForm.cs logical card metrics (@96 DPI) — one design, presented
    // as-is in SwiftUI points (Retina scales it automatically).
    private static let cardWidth: CGFloat = 480
    private static let cardHeight: CGFloat = 64
    private static let updateCardWidth: CGFloat = 200
    private static let updateCardHeight: CGFloat = 44
    private static let maxStoredTranscriptChars = 400

    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?

    private let overlayState = RecordingOverlayState()
    private var overlayWindow: NSPanel?
    private var toastHideToken: UUID?

    init() {}

    // MARK: Public API (all hops to main)

    func showInitializing(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resetSessionText()
            self.overlayState.phase = .initializing
            self.overlayState.audioLevel = 0
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.presentOverlay(animatedResize: false)
        }
    }

    func showRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resetSessionText()
            self.overlayState.phase = .recording
            self.overlayState.audioLevel = 0
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.presentOverlay(animatedResize: true)
        }
    }

    func transitionToRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlayState.phase = .recording
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.presentOverlay(animatedResize: true)
        }
    }

    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlayState.recordingTriggerMode = mode
            self.presentOverlay(animatedResize: animated)
        }
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.overlayState.audioLevel = level
        }
    }

    func updateInterimTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep only the newest tail — the card shows the tail first.
            if trimmed.count > Self.maxStoredTranscriptChars {
                trimmed = "…" + trimmed.suffix(Self.maxStoredTranscriptChars)
            }
            self.overlayState.interimTranscript = trimmed
        }
    }

    func updateTargetApp(_ appName: String) {
        DispatchQueue.main.async { [weak self] in
            self?.overlayState.targetAppName = appName
        }
    }

    func showTranscribing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlayState.phase = .transcribing
            self.overlayState.statusText = "Transcribing..."
            self.presentOverlay(animatedResize: true)
        }
    }

    func showFailureIndicator() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.toastHideToken = nil
            self.overlayState.errorMessage = nil
            self.overlayState.toastID = nil
            self.overlayState.statusText = "Transcription failed"
            self.overlayState.phase = .feedback
            self.presentOverlay(animatedResize: true)
        }
    }

    func showError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var truncated = message
            if truncated.count > Self.maxToastMessageLength {
                truncated = String(truncated.prefix(Self.maxToastMessageLength - 1)) + "…"
            }
            let toastID = UUID()
            self.toastHideToken = toastID
            self.overlayState.errorMessage = truncated
            self.overlayState.toastID = toastID
            self.overlayState.statusText = truncated
            self.overlayState.phase = .feedback
            self.presentOverlay(animatedResize: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.errorToastDuration) { [weak self] in
                guard let self else { return }
                guard self.overlayState.phase == .feedback,
                      self.overlayState.errorMessage == truncated,
                      self.overlayState.toastID == toastID,
                      self.toastHideToken == toastID else { return }
                self.toastHideToken = nil
                self.overlayState.errorMessage = nil
                self.overlayState.toastID = nil
                self.dismissAll()
            }
        }
    }

    func showUpdateAvailable(version: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlayState.isCommandMode = false
            self.overlayState.updateVersion = version
            self.overlayState.phase = .updateAvailable
            self.presentOverlay(animatedResize: true)
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.dismissAll()
        }
    }

    // MARK: Session text

    private func resetSessionText() {
        overlayState.interimTranscript = ""
        overlayState.statusText = ""
        overlayState.errorMessage = nil
        overlayState.toastID = nil
        toastHideToken = nil
    }

    // MARK: Geometry

    private func targetScreen() -> NSScreen? {
        let savedID = UserDefaults.standard.integer(forKey: "overlay_display_id")
        switch savedID {
        case 0:
            return NSScreen.main ?? NSScreen.screens.first
        case -1:
            return NSScreen.screens.first ?? NSScreen.main
        default:
            if let screen = NSScreen.screens.first(where: { $0.displayID == CGDirectDisplayID(savedID) }) {
                return screen
            }
            return NSScreen.screens.first ?? NSScreen.main
        }
    }

    private func cardSize() -> CGSize {
        overlayState.phase == .updateAvailable
            ? CGSize(width: Self.updateCardWidth, height: Self.updateCardHeight)
            : CGSize(width: Self.cardWidth, height: Self.cardHeight)
    }

    // MARK: Presentation

    private func presentOverlay(animatedResize: Bool) {
        guard let screen = targetScreen() else { return }
        let size = cardSize()
        let visible = screen.visibleFrame
        // Top center of the target screen, just under the menu bar / notch —
        // the bottom of the screen is where input fields live.
        let x = min(max(visible.midX - size.width / 2, visible.minX + 8),
                    visible.maxX - size.width - 8)
        let y = min(max(visible.maxY - 12 - size.height, visible.minY + 8),
                    visible.maxY - size.height - 8)
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)

        guard let panel = overlayWindow else {
            makeOverlayPanel(targetFrame: frame, screen: screen)
            return
        }

        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents()
        replaceContentView(panel: panel)
        resize(panel: panel, to: frame, animated: animatedResize)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func makeOverlayPanel(targetFrame: NSRect, screen: NSScreen) {
        let panel = NSPanel(contentRect: targetFrame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents()
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        overlayWindow = panel

        replaceContentView(panel: panel)

        // Drop-in: start above the screen, then animate down with a slight overshoot.
        let hiddenFrame = NSRect(x: targetFrame.origin.x,
                                 y: screen.frame.maxY,
                                 width: targetFrame.width,
                                 height: targetFrame.height)
        panel.setFrame(hiddenFrame, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            context.allowsImplicitAnimation = false
            panel.setFrame(targetFrame, display: true, animate: true)
        }, completionHandler: nil)
    }

    private func replaceContentView(panel: NSPanel) {
        let state = overlayState
        let rootView = RecordingOverlayView(
            state: state,
            onStopButtonPressed: { [weak self] in self?.onStopButtonPressed?() },
            onUpdateOverlayPressed: { [weak self] in self?.onUpdateOverlayPressed?() })
            .frame(width: cardSize().width, height: cardSize().height)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    private func overlayAcceptsMouseEvents() -> Bool {
        let state = overlayState
        if state.phase == .recording && state.recordingTriggerMode == .toggle {
            return true
        }
        return state.phase == .updateAvailable
    }

    private func resize(panel: NSPanel, to frame: NSRect, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.setFrame(frame, display: true, animate: true)
            }, completionHandler: nil)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func dismissAll() {
        toastHideToken = nil
        overlayState.isCommandMode = false
        overlayState.updateVersion = ""
        overlayState.errorMessage = nil
        overlayState.toastID = nil
        overlayState.interimTranscript = ""
        overlayState.statusText = ""
        guard let panel = overlayWindow else { return }
        overlayWindow = nil
        // Detach the SwiftUI hierarchy before closing: repeat-forever animations
        // keep burning Core Animation work while the panel sits in NSApp.windows.
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

// MARK: - Card content (Windows OverlayForm.cs design)

/// The dark floating card: gradient background, rounded 12 border, animated
/// 5-bar equalizer, tail-visible transcript, REC badge and the paste
/// destination pill. Error mode swaps the palette to red, exactly like the
/// Windows overlay.
struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    var onStopButtonPressed: () -> Void = {}
    var onUpdateOverlayPressed: () -> Void = {}

    // Theme.cs palette.
    // Transcript measurement for the FitTail port (Windows OverlayTextFit parity).
    static let transcriptLineHeight = NSFont.systemFont(ofSize: 13).boundingRectForFont.height
    static let transcriptMaxWidth: CGFloat = 350 // card 480 − lead padding − pill column (conservative)

    static func measureHeight(_ text: String) -> CGFloat {
        (text as NSString).boundingRect(
            with: CGSize(width: transcriptMaxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)],
            context: nil).height
    }

    static let cardTop = Color(red: 34 / 255, green: 34 / 255, blue: 41 / 255)
    static let cardBottom = Color(red: 20 / 255, green: 20 / 255, blue: 25 / 255)
    static let cardBorder = Color(red: 64 / 255, green: 64 / 255, blue: 74 / 255)
    static let dangerStrong = Color(red: 206 / 255, green: 70 / 255, blue: 54 / 255)
    static let danger = Color(red: 1.0, green: 99 / 255, blue: 71 / 255)
    static let accent = Color(red: 60 / 255, green: 179 / 255, blue: 113 / 255)
    static let accentBright = Color(red: 128 / 255, green: 205 / 255, blue: 158 / 255)
    static let textBright = Color(red: 240 / 255, green: 240 / 255, blue: 244 / 255)
    static let textCaption = Color(red: 139 / 255, green: 139 / 255, blue: 151 / 255)
    static let recPillBackground = Color(red: 120 / 255, green: 40 / 255, blue: 44 / 255).opacity(48 / 255)
    static let errorPillBackground = Color(red: 24 / 255, green: 24 / 255, blue: 28 / 255).opacity(60 / 255)
    static let destinationPillBackground = Color(red: 38 / 255, green: 38 / 255, blue: 46 / 255)

    var body: some View {
        Group {
            if state.phase == .updateAvailable {
                UpdateAvailableOverlayView { onUpdateOverlayPressed() }
                    .frame(width: 200, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Self.cardTop, Self.cardBottom],
                                                 startPoint: .top, endPoint: .bottom)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Self.cardBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.38), radius: 10, y: 4)
            } else {
                OverlayCard(state: state, onStopButtonPressed: onStopButtonPressed)
            }
        }
    }
}

private struct OverlayCard: View {
    @ObservedObject var state: RecordingOverlayState
    var onStopButtonPressed: () -> Void

    private var isError: Bool {
        if case .feedback = state.phase { return true }
        return false
    }

    private var primaryText: String {
        if isError {
            return state.errorMessage ?? state.statusText
        }
        return state.interimTranscript.isEmpty ? state.statusText : state.interimTranscript
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [RecordingOverlayView.cardTop,
                                              RecordingOverlayView.cardBottom],
                                     startPoint: .top, endPoint: .bottom))
            HStack(spacing: 0) {
                if state.phase == .initializing {
                    InitializingDotsView()
                        .frame(maxWidth: .infinity)
                } else {
                    EqualizerBarsView(level: state.audioLevel, error: isError)
                        .padding(.leading, 14)
                    transcriptBlock
                    Spacer(minLength: 8)
                    pillColumn
                        .padding(.trailing, 10)
                }
            }
        }
        .frame(width: 480, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isError ? RecordingOverlayView.dangerStrong : RecordingOverlayView.cardBorder,
                        lineWidth: 1))
        .shadow(color: .black.opacity(0.38), radius: 10, y: 4)
        .animation(.easeInOut(duration: 0.18), value: state.phase)
    }

    private var transcriptBlock: some View {
        HStack(spacing: 6) {
            if state.isCommandMode {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(RecordingOverlayView.textCaption)
            }
            Text(OverlayTextFitter.fitTail(
                primaryText,
                maxLines: 2,
                lineHeight: RecordingOverlayView.transcriptLineHeight,
                measure: { RecordingOverlayView.measureHeight($0) }))
                .font(.system(size: 13))
                .foregroundColor(isError ? RecordingOverlayView.danger : RecordingOverlayView.textBright)
                // Two wrapped lines with the newest words visible: the text is
                // FitTail-trimmed from the start (Windows OverlayTextFit port).
                // .lineLimit(2) stays only as a safety clamp.
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
    }

    private var pillColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            recPill
            destinationPill
        }
    }

    @ViewBuilder
    private var recPill: some View {
        let pill = HStack(spacing: 5) {
            Circle()
                .fill(isError ? RecordingOverlayView.dangerStrong : RecordingOverlayView.danger)
                .frame(width: 6, height: 6)
            Text(isError ? "ERROR" : "REC")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isError ? RecordingOverlayView.danger : RecordingOverlayView.accentBright)
        }
        .padding(.horizontal, 9)
        .frame(height: 16)
        .background(Capsule().fill(isError ? RecordingOverlayView.errorPillBackground
                                           : RecordingOverlayView.recPillBackground))
        if state.phase == .recording && state.recordingTriggerMode == .toggle && !isError {
            Button(action: onStopButtonPressed) { pill }
                .buttonStyle(.plain)
        } else {
            pill
        }
    }

    private var destinationPill: some View {
        Text("→ \(state.targetAppName.isEmpty ? "clipboard" : state.targetAppName)")
            .font(.system(size: 10))
            .foregroundColor(RecordingOverlayView.textCaption)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 9)
            .frame(height: 16)
            .background(Capsule().fill(RecordingOverlayView.destinationPillBackground))
    }
}

// MARK: - Equalizer (5 bars, Windows TickAnimation math)

private struct EqualizerBarsView: View {
    let level: Float
    var error: Bool = false

    // Fixed phases: stable dance per launch, like the Windows fixed seed.
    private let phases: [Double] = [0.37, 1.93, 2.87, 4.41, 5.62]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    bar(index, date: context.date)
                }
            }
            .frame(width: 32, height: 36)
        }
    }

    // Windows tick targets computed per frame instead of a 30fps Timer — the
    // display link drives the wave, so nothing fights the main runloop.
    private func bar(_ index: Int, date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        let wave = 0.55 + 0.45 * sin(t * 6.36 + phases[index])
        let target = max(Double(level) * wave,
                         0.06 + 0.02 * sin(t * 2.73 + phases[index] * 2))
        let height = max(6, 36 * CGFloat(min(max(target, 0), 1)))
        let colors: [Color] = error
            ? [RecordingOverlayView.dangerStrong, RecordingOverlayView.danger]
            : [RecordingOverlayView.accentBright.opacity(168 / 255), RecordingOverlayView.accent]
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: 4, height: height)
            // Smooths the attack/decay the Windows easing gave the raw level.
            .animation(.easeOut(duration: 0.16), value: level)
    }
}

// MARK: - Initializing dots

struct InitializingDotsView: View {
    @State private var activeDot = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == activeDot ? 0.9 : 0.25))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: activeDot)
            }
        }
        .onReceive(timer) { _ in
            activeDot = (activeDot + 1) % 3
        }
    }
}

// MARK: - Mic-test waveform (Setup screen, 9 bars)

struct WaveformView: View {
    let audioLevel: Float
    var showsActivityPulse: Bool = false

    private let barCount = 9
    private let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]

    var body: some View {
        Group {
            if showsActivityPulse {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    bars(date: context.date, pulse: true)
                }
            } else {
                bars(date: Date(), pulse: false)
            }
        }
        .frame(height: 24)
    }

    private func bars(date: Date, pulse: Bool) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(amplitude: amplitude(at: index, date: date, pulse: pulse))
                    .animation(.spring(response: 0.18 + distanceFromCenter(index) * 0.06,
                                       dampingFraction: 0.88)
                        .delay(distanceFromCenter(index) * 0.01),
                               value: audioLevel)
            }
        }
    }

    private func distanceFromCenter(_ index: Int) -> CGFloat {
        CGFloat(abs(index - (barCount - 1) / 2))
    }

    private func amplitude(at index: Int, date: Date, pulse: Bool) -> CGFloat {
        let base = min(max(audioLevel, 0) * Float(multipliers[index]), 1)
        guard pulse else { return CGFloat(base) }
        let t = date.timeIntervalSinceReferenceDate
        let travelingWave = 0.5 + 0.5 * sin(t * 6.2 - Double(index) * 0.78)
        let shimmer = 0.5 + 0.5 * sin(t * 3.1 + Double(index) * 0.5)
        let pulseAmount = travelingWave * 0.22 + shimmer * 0.06
        let saturationRelief = Double(base) * (0.74 + pulseAmount)
        let quietPulse = (1 - Double(base)) * (0.04 + pulseAmount * 0.28)
        return CGFloat(min(saturationRelief + quietPulse, 1.0))
    }
}

struct WaveformBar: View {
    let amplitude: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 3, height: 2 + (22 - 2) * min(max(amplitude, 0), 1))
    }
}

// MARK: - Update banner

struct UpdateAvailableOverlayView: View {
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(RecordingOverlayView.textBright)
                Text("Update Available")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RecordingOverlayView.textBright)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
