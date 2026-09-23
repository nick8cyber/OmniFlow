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
    @Published var updateVersion: String = ""
    @Published var errorMessage: String?
    @Published var toastID: UUID?
}

final class RecordingOverlayManager {
    private static let wingWidth: CGFloat = 36
    private static let maxToastMessageLength = 90
    private static let errorToastDuration: TimeInterval = 6.0

    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?

    private let overlayState = RecordingOverlayState()
    private var overlayWindow: NSPanel?
    private var lockedOverlayWidth: CGFloat?
    private var toastHideToken: UUID?

    init() {}

    // MARK: Public API (all hops to main)

    func showInitializing(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockedOverlayWidth = nil
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
            self.updateOverlayLayout(animated: true)
        }
    }

    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlayState.recordingTriggerMode = mode
            self.updateOverlayLayout(animated: animated)
        }
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.overlayState.audioLevel = level
        }
    }

    func showTranscribing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockedOverlayWidth = self.overlayWindow?.frame.width ?? self.pillOverlayWidth()
            self.overlayState.phase = .transcribing
            self.presentOverlay(animatedResize: true)
        }
    }

    func showFailureIndicator() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockedOverlayWidth = nil
            self.overlayState.errorMessage = nil
            self.overlayState.toastID = nil
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
            self.lockedOverlayWidth = nil
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
            self.lockedOverlayWidth = nil
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

    private func screenHasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    private func notchWidth(_ screen: NSScreen) -> CGFloat {
        guard screenHasNotch(screen),
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return 0 }
        return screen.frame.width - leftArea.width - rightArea.width
    }

    private func notchOverlap(_ screen: NSScreen) -> CGFloat {
        screen.frame.maxY - screen.visibleFrame.maxY
    }

    private func usesCompactOverlay() -> Bool {
        UserDefaults.standard.object(forKey: "use_compact_overlay") as? Bool ?? true
    }

    private func useWingedLayout(screen: NSScreen) -> Bool {
        guard screenHasNotch(screen), usesCompactOverlay() else { return false }
        switch overlayState.phase {
        case .recording, .initializing, .transcribing:
            return true
        case .feedback:
            let message = overlayState.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty
        case .updateAvailable:
            return false
        }
    }

    private func pillOverlayWidth() -> CGFloat {
        let state = overlayState
        switch state.phase {
        case .transcribing:
            if let locked = lockedOverlayWidth { return locked }
        case .feedback:
            let message = state.errorMessage ?? ""
            if message.isEmpty {
                return 92
            }
            return min(420, max(180, CGFloat(message.count) * 6.8 + 60))
        case .updateAvailable:
            return 190
        default:
            break
        }
        let base: CGFloat
        if state.isCommandMode {
            base = 180
        } else if state.phase == .recording && state.recordingTriggerMode == .toggle {
            base = 150
        } else {
            base = 92
        }
        return base
    }

    // MARK: Presentation

    private func presentOverlay(animatedResize: Bool) {
        guard let screen = targetScreen() else { return }
        let winged = useWingedLayout(screen: screen)
        let hasNotch = screenHasNotch(screen)
        let notch = notchWidth(screen)
        let overlap = notchOverlap(screen)

        let width: CGFloat
        let height: CGFloat
        let x: CGFloat
        let y: CGFloat
        if winged {
            width = Self.wingWidth + notch + Self.wingWidth
            height = overlap
            let leftArea = screen.auxiliaryTopLeftArea
            x = (leftArea?.maxX ?? (screen.frame.midX - notch / 2)) - Self.wingWidth
            y = screen.frame.maxY - height
        } else {
            let forceDropDownPill = overlayState.phase == .feedback && !(overlayState.errorMessage ?? "").isEmpty
            var pillHeight: CGFloat
            if usesCompactOverlay() && !forceDropDownPill {
                pillHeight = overlap
            } else {
                pillHeight = 38 + (hasNotch ? overlap : 0)
            }
            var baseWidth = pillOverlayWidth()
            if hasNotch {
                baseWidth = max(notch, baseWidth)
            }
            width = baseWidth
            height = pillHeight
            x = screen.frame.midX - width / 2
            y = screen.frame.maxY - height
        }
        let frame = NSRect(x: x, y: y, width: width, height: height)

        guard let panel = overlayWindow else {
            makeOverlayPanel(width: width, height: height, screen: screen, winged: winged,
                             notchWidth: notch, targetFrame: frame)
            return
        }

        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents()
        replaceContentView(panel: panel, width: width, height: height, winged: winged, notchWidth: notch)
        resize(panel: panel, to: frame, animated: animatedResize)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func makeOverlayPanel(width: CGFloat, height: CGFloat, screen: NSScreen,
                                  winged: Bool, notchWidth: CGFloat, targetFrame: NSRect) {
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

        replaceContentView(panel: panel, width: width, height: height, winged: winged, notchWidth: notchWidth)

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

    private func replaceContentView(panel: NSPanel, width: CGFloat, height: CGFloat,
                                    winged: Bool, notchWidth: CGFloat) {
        let state = overlayState
        let rootView: AnyView
        if winged {
            rootView = AnyView(
                WingedRecordingView(state: state,
                                    notchWidth: notchWidth,
                                    onStopButtonPressed: { [weak self] in self?.onStopButtonPressed?() },
                                    onUpdateOverlayPressed: { [weak self] in self?.onUpdateOverlayPressed?() })
                    .frame(width: width, height: height)
            )
        } else {
            rootView = AnyView(
                RecordingOverlayView(state: state,
                                     onStopButtonPressed: { [weak self] in self?.onStopButtonPressed?() },
                                     onUpdateOverlayPressed: { [weak self] in self?.onUpdateOverlayPressed?() })
                    .frame(width: width, height: height)
            )
        }
        let hostingView = NSHostingView(rootView: rootView
            .background(Color.black)
            .clipShape(Self.bottomRoundedShape(radius: 6))
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    private static func bottomRoundedShape(radius: CGFloat) -> AnyShape {
        if #available(macOS 14.0, *) {
            return AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: radius,
                                                   bottomTrailingRadius: radius))
        }
        return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
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

    private func updateOverlayLayout(animated: Bool) {
        guard overlayWindow != nil else { return }
        presentOverlay(animatedResize: animated)
    }

    private func dismissAll() {
        lockedOverlayWidth = nil
        overlayState.isCommandMode = false
        overlayState.updateVersion = ""
        toastHideToken = nil
        overlayState.errorMessage = nil
        overlayState.toastID = nil
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

// MARK: - Pill content

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    var onStopButtonPressed: () -> Void = {}
    var onUpdateOverlayPressed: () -> Void = {}

    var body: some View {
        Group {
            if state.phase == .feedback, let message = state.errorMessage, !message.isEmpty {
                ErrorOverlayView(message: message)
            } else if state.phase == .feedback {
                FailureIndicatorView()
            } else if state.phase == .updateAvailable {
                UpdateAvailableOverlayView { onUpdateOverlayPressed() }
            } else {
                ZStack {
                    centerContent
                    HStack {
                        HStack {
                            if state.isCommandMode {
                                CommandModeIndicator()
                            }
                        }
                        .frame(width: 24)
                        Spacer()
                        HStack {
                            if state.phase == .recording && state.recordingTriggerMode == .toggle {
                                Button(action: onStopButtonPressed) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.red.opacity(0.92))
                                            .frame(width: 14, height: 14)
                                        Image(systemName: "stop.fill")
                                            .font(.system(size: 7, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .buttonStyle(.plain)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.phase)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.recordingTriggerMode)
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.isCommandMode)
    }

    @ViewBuilder
    private var centerContent: some View {
        switch state.phase {
        case .initializing:
            InitializingDotsView()
        case .recording:
            WaveformView(audioLevel: state.audioLevel, showsActivityPulse: true)
        default:
            ProcessingIndicatorView()
        }
    }
}

// MARK: - Winged content

struct WingedRecordingView: View {
    @ObservedObject var state: RecordingOverlayState
    let notchWidth: CGFloat
    var onStopButtonPressed: () -> Void = {}
    var onUpdateOverlayPressed: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: 36)
            Color.black
                .frame(width: max(notchWidth, 0))
            rightWing
                .frame(width: 36)
        }
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: state.phase)
    }

    @ViewBuilder
    private var leftWing: some View {
        switch state.phase {
        case .feedback:
            Color.clear
        case .initializing:
            InitializingDotsView()
        case .recording:
            VStack(spacing: 1) {
                if state.isCommandMode {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                }
                CompactWaveformView(audioLevel: state.audioLevel)
            }
        default:
            CompactProcessingIndicatorView()
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        if state.phase == .feedback {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.92))
                    .frame(width: 14, height: 14)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white)
            }
        } else if state.phase == .recording && state.recordingTriggerMode == .toggle {
            Button(action: onStopButtonPressed) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.92))
                        .frame(width: 14, height: 14)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            Color.clear
        }
    }
}

// MARK: - Waveform (pill, 9 bars)

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

// MARK: - Compact waveform (wing, 5 bars)

struct CompactWaveformView: View {
    let audioLevel: Float
    var showsActivityPulse: Bool = false

    private let barCount = 5
    private let multipliers: [CGFloat] = [0.5, 0.75, 1.0, 0.75, 0.5]

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
        .frame(height: 18)
    }

    private func bars(date: Date, pulse: Bool) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<barCount, id: \.self) { index in
                CompactWaveformBar(amplitude: amplitude(at: index, date: date, pulse: pulse))
                    .animation(.spring(response: 0.18, dampingFraction: 0.88), value: audioLevel)
            }
        }
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

struct CompactWaveformBar: View {
    let amplitude: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 2, height: 2 + (14 - 2) * min(max(amplitude, 0), 1))
    }
}

// MARK: - Processing indicators

struct ProcessingWaveformView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    ProcessingPill(amplitude: amplitude(at: index, date: context.date),
                                   opacity: opacity(at: index, date: context.date),
                                   width: 4, minHeight: 4, maxHeight: 18)
                }
            }
            .frame(height: 20)
        }
    }

    private func waveformPhase(at index: Int, date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let raw = (t - Double(index) * 0.11).truncatingRemainder(dividingBy: 1.05)
        let positive = raw < 0 ? raw + 1.05 : raw
        return positive / 1.05
    }

    private func amplitude(at index: Int, date: Date) -> CGFloat {
        let phase = waveformPhase(at: index, date: date)
        let wave = 0.5 + 0.5 * sin(phase * 2 * .pi - .pi / 2)
        let pulse = pow(wave, 1.9)
        let centerDistance = CGFloat(abs(index - 2)) / 2
        return min(0.18 + (1 - centerDistance) * 0.1 + CGFloat(pulse) * 0.68, 1)
    }

    private func opacity(at index: Int, date: Date) -> Double {
        let phase = waveformPhase(at: index, date: date)
        let wave = 0.5 + 0.5 * sin(phase * 2 * .pi - .pi / 2)
        let pulse = pow(wave, 1.9)
        return 0.42 + pulse * 0.52
    }
}

struct CompactProcessingWaveformView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    ProcessingPill(amplitude: amplitude(at: index, date: context.date),
                                   opacity: opacity(at: index, date: context.date),
                                   width: 2, minHeight: 2, maxHeight: 12)
                }
            }
            .frame(height: 18)
        }
    }

    private func waveformPhase(at index: Int, date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let raw = (t - Double(index) * 0.11).truncatingRemainder(dividingBy: 1.05)
        let positive = raw < 0 ? raw + 1.05 : raw
        return positive / 1.05
    }

    private func amplitude(at index: Int, date: Date) -> CGFloat {
        let phase = waveformPhase(at: index, date: date)
        let wave = 0.5 + 0.5 * sin(phase * 2 * .pi - .pi / 2)
        let pulse = pow(wave, 1.9)
        let centerDistance = CGFloat(abs(index - 2)) / 2
        return min(0.18 + (1 - centerDistance) * 0.1 + CGFloat(pulse) * 0.68, 1)
    }

    private func opacity(at index: Int, date: Date) -> Double {
        let phase = waveformPhase(at: index, date: date)
        let wave = 0.5 + 0.5 * sin(phase * 2 * .pi - .pi / 2)
        let pulse = pow(wave, 1.9)
        return 0.42 + pulse * 0.52
    }
}

private struct ProcessingPill: View {
    let amplitude: CGFloat
    let opacity: Double
    let width: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(opacity))
            .frame(width: width,
                   height: minHeight + (maxHeight - minHeight) * min(max(amplitude, 0), 1))
    }
}

struct ProcessingIndicatorView: View {
    @State private var showSpinner = false

    var body: some View {
        ZStack {
            if showSpinner {
                ProcessingSpinnerView(size: 16, lineWidth: 2.5)
                    .transition(.opacity)
            } else {
                ProcessingWaveformView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showSpinner)
        .task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            showSpinner = true
        }
    }
}

struct CompactProcessingIndicatorView: View {
    @State private var showSpinner = false

    var body: some View {
        ZStack {
            if showSpinner {
                ProcessingSpinnerView(size: 12, lineWidth: 2.0)
                    .transition(.opacity)
            } else {
                CompactProcessingWaveformView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showSpinner)
        .task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            showSpinner = true
        }
    }
}

struct ProcessingSpinnerView: View {
    let size: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation += 360
                }
            }
            .rotationEffect(.degrees(rotation))
    }

    @State private var rotation = 0.0
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

// MARK: - Small indicators

struct CommandModeIndicator: View {
    var body: some View {
        Image(systemName: "pencil")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.92))
            .frame(width: 16, height: 16)
    }
}

struct FailureIndicatorView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.92))
                .frame(width: 20, height: 20)
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 20, height: 20)
    }
}

struct ErrorOverlayView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.red.opacity(0.92))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct UpdateAvailableOverlayView: View {
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("Update Available")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
