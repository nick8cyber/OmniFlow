import Foundation
import AppKit

@MainActor
final class SetupTestHotkeyHarness: ObservableObject {
    private let hotkeyManager = HotkeyManager()
    private let sessionController = DictationShortcutSessionController()
    private(set) var startDelay: TimeInterval = 0

    var isTranscribing = false
    var onAction: ((DictationShortcutAction) -> Void)?

    init() {}

    func start(configuration: ShortcutConfiguration, startDelay: TimeInterval) throws {
        stop()
        self.startDelay = startDelay
        hotkeyManager.onShortcutEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event: event)
            }
        }
        try hotkeyManager.start(configuration: configuration)
    }

    func stop() {
        hotkeyManager.stop()
    }

    func resetSession() {
        sessionController.reset()
    }

    private func handle(event: ShortcutEvent) {
        guard let action = sessionController.handle(event: event, isTranscribing: isTranscribing) else { return }
        onAction?(action)
    }
}
