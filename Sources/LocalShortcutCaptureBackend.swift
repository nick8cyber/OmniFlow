import AppKit

/// Listens to local (own-app) events only while the user records a shortcut in
/// Settings/Setup. Every local event is swallowed (`return nil`) so nothing
/// leaks into other windows.
final class LocalShortcutCaptureBackend {
    var onInputEvent: ((ShortcutInputEvent) -> Void)?
    var onKeyDownEvent: ((NSEvent) -> Void)?

    private var flagsChangedMonitor: Any?
    private var keyDownMonitor: Any?
    private var pressedModifierKeyCodes: Set<UInt16> = []

    init() {}

    func start() {
        stop()
        if ModifierKeyEventState.currentFunctionKeyIsDown() {
            pressedModifierKeyCodes.insert(ModifierKeyEventState.fnKeyCode)
        }
        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return nil
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return nil
        }
    }

    func stop() {
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
        flagsChangedMonitor = nil
        keyDownMonitor = nil
        pressedModifierKeyCodes = []
    }

    deinit {
        stop()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard ShortcutBinding.modifierKeyCodes.contains(event.keyCode),
              let isDown = ModifierKeyEventState.isKeyDown(for: event) else { return }
        if isDown {
            pressedModifierKeyCodes.insert(event.keyCode)
        } else {
            pressedModifierKeyCodes.remove(event.keyCode)
        }
        onInputEvent?(.modifierChanged(keyCode: event.keyCode, isDown: isDown))
    }

    private func handleKeyDown(_ event: NSEvent) {
        if !ShortcutBinding.modifierKeyCodes.contains(event.keyCode) {
            onInputEvent?(.modifierSnapshot(
                ModifierKeyEventState.pressedModifierKeyCodes(
                    for: event,
                    trustedFunctionKeyIsDown: pressedModifierKeyCodes.contains(ModifierKeyEventState.fnKeyCode))))
            onInputEvent?(.keyChanged(keyCode: event.keyCode,
                                      isDown: true,
                                      isRepeat: event.isARepeat))
        }
        onKeyDownEvent?(event)
    }
}
