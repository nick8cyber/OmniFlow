import AppKit
import Carbon.HIToolbox

enum ModifierKeyEventState {
    static let fnKeyCode: UInt16 = 63

    private static let mappedFlags: [UInt16: NSEvent.ModifierFlags] = [
        54: NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERCMDKEYMASK)),
        55: NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICELCMDKEYMASK)),
        56: NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICELSHIFTKEYMASK)),
        58: NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICELALTKEYMASK)),
        59: NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICELCTLKEYMASK)),
        60: NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERSHIFTKEYMASK)),
        61: NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERALTKEYMASK)),
        62: NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERCTLKEYMASK)),
        63: .function
    ]

    static func isKeyDown(for event: NSEvent) -> Bool? {
        guard let mappedFlag = mappedFlags[event.keyCode] else { return nil }
        return event.modifierFlags.contains(mappedFlag)
    }

    static func pressedModifierKeyCodes(for event: NSEvent,
                                        trustedFunctionKeyIsDown: Bool? = nil) -> Set<UInt16> {
        var codes: Set<UInt16> = []
        for (keyCode, mappedFlag) in mappedFlags {
            if keyCode == fnKeyCode, let trusted = trustedFunctionKeyIsDown {
                // macOS sets the .function flag for arrows/F-keys/navigation regardless of
                // the physical Fn key, so a trusted snapshot wins over the event flag.
                if trusted {
                    codes.insert(keyCode)
                }
            } else if event.modifierFlags.contains(mappedFlag) {
                codes.insert(keyCode)
            }
        }
        return codes
    }

    static func currentFunctionKeyIsDown() -> Bool {
        NSEvent.modifierFlags.contains(.function)
    }
}
