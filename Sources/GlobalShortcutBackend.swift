import AppKit
import CoreGraphics
import Foundation

enum GlobalShortcutBackendError: LocalizedError {
    case eventTapUnavailable
    case eventTapRunLoopSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "OmniFlow"
            return "Global shortcut monitoring could not start. \(appName) requires keyboard monitoring permission for global shortcuts."
        case .eventTapRunLoopSourceUnavailable:
            return "Global shortcut monitoring could not start because the event tap run loop source could not be created."
        }
    }
}

final class GlobalShortcutBackend {
    var onInputEvent: ((ShortcutInputEvent) -> ShortcutConsumeDecision)?
    var onEscapeKeyPressed: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnKeyIsDown = false

    init() {}

    func start() throws {
        stop()
        try installEventTap()
        fnKeyIsDown = ModifierKeyEventState.currentFunctionKeyIsDown()
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        notifyBackendReset()
    }

    deinit {
        stop()
    }

    // MARK: - Tap installation

    private func installEventTap() throws {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: eventMask,
                                          callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let backend = Unmanaged<GlobalShortcutBackend>.fromOpaque(userInfo).takeUnretainedValue()
            return backend.handleEventTap(type: type, event: event)
        },
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw GlobalShortcutBackendError.eventTapUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw GlobalShortcutBackendError.eventTapRunLoopSourceUnavailable
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTap = tap
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func notifyBackendReset() {
        fnKeyIsDown = false
        _ = onInputEvent?(.backendReset)
    }

    // MARK: - Tap callback

    private func handleEventTap(type: CGEventType,
                                event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            notifyBackendReset()
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            fnKeyIsDown = ModifierKeyEventState.currentFunctionKeyIsDown()
            return Unmanaged.passUnretained(event)
        case .flagsChanged, .keyDown, .keyUp:
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }
            return handleNSEvent(nsEvent, cgEvent: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleNSEvent(_ nsEvent: NSEvent,
                               cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        func passThrough() -> Unmanaged<CGEvent>? {
            Unmanaged.passUnretained(cgEvent)
        }

        switch nsEvent.type {
        case .flagsChanged:
            guard ShortcutBinding.modifierKeyCodes.contains(nsEvent.keyCode),
                  let isDown = ModifierKeyEventState.isKeyDown(for: nsEvent) else {
                return passThrough()
            }
            if nsEvent.keyCode == ModifierKeyEventState.fnKeyCode {
                fnKeyIsDown = isDown
            }
            let consume = onInputEvent?(.modifierChanged(keyCode: nsEvent.keyCode,
                                                         isDown: isDown)) == .consume
            return consume ? nil : passThrough()

        case .keyDown:
            if nsEvent.keyCode == 53 {
                guard !nsEvent.isARepeat else { return passThrough() }
                let consume = onEscapeKeyPressed?() ?? false
                return consume ? nil : passThrough()
            }
            guard !ShortcutBinding.modifierKeyCodes.contains(nsEvent.keyCode) else {
                return passThrough()
            }
            let snapshotConsume = onInputEvent?(
                .modifierSnapshot(ModifierKeyEventState.pressedModifierKeyCodes(
                    for: nsEvent,
                    trustedFunctionKeyIsDown: fnKeyIsDown))) == .consume
            let keyConsume = onInputEvent?(.keyChanged(keyCode: nsEvent.keyCode,
                                                       isDown: true,
                                                       isRepeat: nsEvent.isARepeat)) == .consume
            return (snapshotConsume || keyConsume) ? nil : passThrough()

        case .keyUp:
            guard !ShortcutBinding.modifierKeyCodes.contains(nsEvent.keyCode) else {
                return passThrough()
            }
            let snapshotConsume = onInputEvent?(
                .modifierSnapshot(ModifierKeyEventState.pressedModifierKeyCodes(
                    for: nsEvent,
                    trustedFunctionKeyIsDown: fnKeyIsDown))) == .consume
            let keyConsume = onInputEvent?(.keyChanged(keyCode: nsEvent.keyCode,
                                                       isDown: false,
                                                       isRepeat: false)) == .consume
            return (snapshotConsume || keyConsume) ? nil : passThrough()

        default:
            return passThrough()
        }
    }
}
