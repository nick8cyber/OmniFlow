import Foundation

struct ShortcutModifiers: OptionSet, Hashable, Codable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let control = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)
    static let function = ShortcutModifiers(rawValue: 1 << 4)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var orderedDisplayNames: [String] {
        var names: [String] = []
        if contains(.command) { names.append("Cmd ⌘") }
        if contains(.control) { names.append("Ctrl ⌃") }
        if contains(.option) { names.append("Option ⌥") }
        if contains(.shift) { names.append("Shift ⇧") }
        if contains(.function) { names.append("Fn 🌐") }
        return names
    }
}

enum ShortcutBindingKind: String, Codable {
    case disabled, key, modifierKey
}

enum RecordingTriggerMode: String, Codable {
    case hold, toggle

    var badgeTitle: String {
        switch self {
        case .hold: return "Hold"
        case .toggle: return "Tap"
        }
    }
}

enum ShortcutRole {
    case hold, toggle, copyAgain

    var title: String {
        switch self {
        case .hold: return "Hold to Talk"
        case .toggle: return "Tap to Toggle"
        case .copyAgain: return "Paste Again"
        }
    }
}

enum ShortcutEvent: Equatable {
    case holdActivated, holdDeactivated, toggleActivated, toggleDeactivated, copyAgainTriggered
}

struct ShortcutConfiguration: Equatable {
    let hold: ShortcutBinding
    let toggle: ShortcutBinding
    let copyAgain: ShortcutBinding
    let permittedAdditionalExactMatchModifiers: ShortcutModifiers

    init(hold: ShortcutBinding,
         toggle: ShortcutBinding,
         copyAgain: ShortcutBinding = .disabled,
         permittedAdditionalExactMatchModifiers: ShortcutModifiers = []) {
        self.hold = hold
        self.toggle = toggle
        self.copyAgain = copyAgain
        self.permittedAdditionalExactMatchModifiers = permittedAdditionalExactMatchModifiers
    }

    static let disabled = ShortcutConfiguration(hold: .disabled,
                                                toggle: .disabled,
                                                copyAgain: .disabled)
}

enum ShortcutPreset: String, CaseIterable, Identifiable, Codable {
    case fnKey = "fn"
    case rightOption = "rightOption"
    case f5 = "f5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fnKey: return "Fn 🌐"
        case .rightOption: return "Right Option ⌥"
        case .f5: return "F5"
        }
    }

    var binding: ShortcutBinding {
        switch self {
        case .fnKey:
            return ShortcutBinding(keyCode: 63, keyDisplay: "Fn", modifiers: [],
                                   kind: .modifierKey, preset: self)
        case .rightOption:
            return ShortcutBinding(keyCode: 61, keyDisplay: "Right Option", modifiers: [],
                                   kind: .modifierKey, preset: self)
        case .f5:
            return ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [],
                                   kind: .key, preset: self)
        }
    }
}

struct ShortcutBinding: Codable, Hashable, Identifiable, Equatable {
    let keyCode: UInt16
    let keyDisplay: String
    let modifiers: ShortcutModifiers
    let kind: ShortcutBindingKind
    let preset: ShortcutPreset?
    let exactModifierKeyCodes: Set<UInt16>?

    init(keyCode: UInt16,
         keyDisplay: String,
         modifiers: ShortcutModifiers,
         kind: ShortcutBindingKind,
         preset: ShortcutPreset?,
         exactModifierKeyCodes: Set<UInt16>? = nil) {
        self.keyCode = keyCode
        self.keyDisplay = keyDisplay
        self.modifiers = modifiers
        self.kind = kind
        self.preset = preset
        self.exactModifierKeyCodes = exactModifierKeyCodes
    }

    // MARK: - Derived properties

    var id: String {
        let exactIDs = Self.orderedExactModifierKeyCodes(exactModifierKeyCodes ?? [])
            .map(String.init)
            .joined(separator: ",")
        return "\(kind.rawValue):\(keyCode):\(modifiers.rawValue):\(preset?.rawValue ?? "custom"):\(exactIDs)"
    }

    var isDisabled: Bool { kind == .disabled }
    var isCustom: Bool { preset == nil && !isDisabled }

    var displayName: String {
        guard !isDisabled else { return "Disabled" }
        var parts = modifierDisplayNames
        parts.append(primaryDisplayName)
        return parts.joined(separator: " + ")
    }

    private var primaryDisplayName: String {
        if kind == .modifierKey, let label = Self.exactModifierDisplayLabel(for: keyCode) {
            return label
        }
        return keyDisplay
    }

    var selectionTitle: String { preset?.title ?? displayName }

    var specificityScore: Int { modifierDisplayNames.count }

    var usesFnKey: Bool {
        !isDisabled && (keyCode == 63 || modifiers.contains(.function))
    }

    var requiresExactModifierMatch: Bool {
        kind == .modifierKey || exactModifierKeyCodes != nil
    }

    var modifierDisplayNames: [String] {
        Self.modifierDisplayNames(for: modifiers, exactModifierKeyCodes: exactModifierKeyCodes)
    }

    // MARK: - Transforms

    func withAddedModifiers(_ extraModifiers: ShortcutModifiers) -> ShortcutBinding {
        guard !isDisabled else { return self }
        let combined = modifiers.union(extraModifiers)
        let combinedExact: Set<UInt16>?
        if let exact = exactModifierKeyCodes {
            let added = Self.exactModifierKeyCodesPreservingSides(for: extraModifiers)
            combinedExact = Self.normalizedExactModifierKeyCodes(exact.union(added))
        } else {
            combinedExact = nil
        }
        return ShortcutBinding(keyCode: keyCode,
                               keyDisplay: keyDisplay,
                               modifiers: combined,
                               kind: kind,
                               preset: preset,
                               exactModifierKeyCodes: combinedExact)
    }

    func normalizedForStorageMigration() -> ShortcutBinding {
        let normalizedExact = Self.normalizedExactModifierKeyCodes(exactModifierKeyCodes)
        let extraCodes: Set<UInt16>
        if kind == .modifierKey, let normalizedExact {
            extraCodes = normalizedExact.subtracting([keyCode])
        } else {
            extraCodes = normalizedExact ?? []
        }
        let inferredModifiers = Self.modifiers(for: extraCodes)
        let normalizedModifiers = modifiers.union(inferredModifiers)
        if normalizedExact == exactModifierKeyCodes && normalizedModifiers == modifiers {
            return self
        }
        return ShortcutBinding(keyCode: keyCode,
                               keyDisplay: keyDisplay,
                               modifiers: normalizedModifiers,
                               kind: kind,
                               preset: preset,
                               exactModifierKeyCodes: normalizedExact)
    }

    func conflicts(with other: ShortcutBinding) -> Bool {
        guard !isDisabled, !other.isDisabled else { return false }
        guard kind == other.kind else { return false }
        guard kind == .key || kind == .modifierKey else { return false }
        guard keyCode == other.keyCode else { return false }

        let codes = Array(Self.modifierKeyCodes).sorted()
        for mask in 0..<(1 << codes.count) {
            var pressed: Set<UInt16> = []
            for (index, code) in codes.enumerated() where mask & (1 << index) != 0 {
                pressed.insert(code)
            }
            if isActive(for: pressed) && other.isActive(for: pressed)
                && specificityScore == other.specificityScore {
                return true
            }
        }
        return false
    }

    func isActive(for pressedModifierKeyCodes: Set<UInt16>) -> Bool {
        guard !isDisabled else { return false }
        let pressedModifiers = Self.modifiers(for: pressedModifierKeyCodes)
        guard pressedModifiers.isSuperset(of: modifiers) else { return false }
        if let exact = exactModifierKeyCodes,
           !Self.exactModifierKeyCodesMatch(pressedModifierKeyCodes,
                                            exactModifierKeyCodes: exact) {
            return false
        }
        switch kind {
        case .key:
            return true
        case .modifierKey:
            return pressedModifierKeyCodes.contains(keyCode)
        case .disabled:
            return false
        }
    }

    // MARK: - Defaults

    static let disabled = ShortcutBinding(keyCode: 0, keyDisplay: "Disabled", modifiers: [],
                                          kind: .disabled, preset: nil)
    static let defaultHold = ShortcutPreset.fnKey.binding
    static let defaultToggle = defaultHold.withAddedModifiers(.command)

    // MARK: - Modifier keycode tables

    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    static let modifierDisplayOrder: [UInt16] = [55, 54, 59, 62, 58, 61, 56, 60, 63]

    static func logicalModifier(forKeyCode keyCode: UInt16) -> ShortcutModifiers? {
        switch keyCode {
        case 54, 55: return .command
        case 59, 62: return .control
        case 58, 61: return .option
        case 56, 60: return .shift
        case 63: return .function
        default: return nil
        }
    }

    static func modifier(forKeyCode keyCode: UInt16) -> ShortcutModifiers? {
        logicalModifier(forKeyCode: keyCode)
    }

    static func modifiers(for pressedModifierKeyCodes: Set<UInt16>) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        for code in pressedModifierKeyCodes {
            if let logical = logicalModifier(forKeyCode: code) {
                result.insert(logical)
            }
        }
        return result
    }

    static func canonicalModifierKeyCode(for keyCode: UInt16) -> UInt16 {
        switch keyCode {
        case 54: return 55
        case 60: return 56
        case 61: return 58
        case 62: return 59
        default: return keyCode
        }
    }

    static func exactModifierKeyCodes(for modifiers: ShortcutModifiers) -> Set<UInt16> {
        var codes: Set<UInt16> = []
        if modifiers.contains(.command) { codes.insert(55) }
        if modifiers.contains(.control) { codes.insert(59) }
        if modifiers.contains(.option) { codes.insert(58) }
        if modifiers.contains(.shift) { codes.insert(56) }
        if modifiers.contains(.function) { codes.insert(63) }
        return codes
    }

    static func exactModifierKeyCodesPreservingSides(for modifiers: ShortcutModifiers) -> Set<UInt16> {
        var codes: Set<UInt16> = []
        if modifiers.contains(.command) { codes.formUnion([54, 55]) }
        if modifiers.contains(.control) { codes.formUnion([59, 62]) }
        if modifiers.contains(.option) { codes.formUnion([58, 61]) }
        if modifiers.contains(.shift) { codes.formUnion([56, 60]) }
        if modifiers.contains(.function) { codes.insert(63) }
        return codes
    }

    static func matchingModifierKeyCodes(for modifiers: ShortcutModifiers) -> Set<UInt16> {
        Set(modifierKeyCodes.filter { code in
            guard let logical = logicalModifier(forKeyCode: code) else { return false }
            return modifiers.contains(logical)
        })
    }

    static func logicalModifierDisplayLabel(for keyCode: UInt16) -> String {
        switch keyCode {
        case 55: return "Command"
        case 59: return "Control"
        case 58: return "Option"
        case 56: return "Shift"
        case 63: return "Fn"
        default: return "Modifier"
        }
    }

    static func exactModifierDisplayLabel(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 55: return "Cmd ⌘"
        case 54: return "Right Cmd ⌘"
        case 59: return "Ctrl ⌃"
        case 62: return "Right Ctrl ⌃"
        case 58: return "Option ⌥"
        case 61: return "Right Option ⌥"
        case 56: return "Shift ⇧"
        case 60: return "Right Shift ⇧"
        case 63: return "Fn"
        default: return nil
        }
    }

    static func normalizedExactModifierKeyCodes(_ keyCodes: Set<UInt16>?) -> Set<UInt16>? {
        guard let keyCodes else { return nil }
        let filtered = keyCodes.intersection(modifierKeyCodes)
        return filtered.isEmpty ? nil : filtered
    }

    static func orderedExactModifierKeyCodes(_ keyCodes: Set<UInt16>) -> [UInt16] {
        modifierDisplayOrder.filter { keyCodes.contains($0) }
    }

    // MARK: - Exact matching

    private struct ModifierKeyCodeMatchSpec {
        let modifier: ShortcutModifiers
        let keyCodes: Set<UInt16>
    }

    private static let modifierKeyCodeMatchSpecs: [ModifierKeyCodeMatchSpec] = [
        ModifierKeyCodeMatchSpec(modifier: .command, keyCodes: [54, 55]),
        ModifierKeyCodeMatchSpec(modifier: .control, keyCodes: [59, 62]),
        ModifierKeyCodeMatchSpec(modifier: .option, keyCodes: [58, 61]),
        ModifierKeyCodeMatchSpec(modifier: .shift, keyCodes: [56, 60]),
        ModifierKeyCodeMatchSpec(modifier: .function, keyCodes: [63])
    ]

    static func exactModifierKeyCodesMatch(_ pressed: Set<UInt16>,
                                           exactModifierKeyCodes: Set<UInt16>,
                                           permittedAdditionalExactMatchModifiers: ShortcutModifiers = []) -> Bool {
        let exact = normalizedExactModifierKeyCodes(exactModifierKeyCodes) ?? []
        for spec in modifierKeyCodeMatchSpecs {
            let exactKeys = exact.intersection(spec.keyCodes)
            let pressedKeys = pressed.intersection(spec.keyCodes)
            if exactKeys.isEmpty {
                if !pressedKeys.isEmpty
                    && !permittedAdditionalExactMatchModifiers.contains(spec.modifier) {
                    return false
                }
            } else if exactKeys.count == spec.keyCodes.count {
                if pressedKeys.isEmpty || !pressedKeys.isSubset(of: exactKeys) {
                    return false
                }
            } else {
                if pressedKeys != exactKeys {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Display names

    private struct ModifierDisplaySpec {
        let modifier: ShortcutModifiers
        let genericLabel: String
        let sideLabels: [(code: UInt16, label: String)]
    }

    private static let modifierDisplaySpecs: [ModifierDisplaySpec] = [
        ModifierDisplaySpec(modifier: .command, genericLabel: "Cmd ⌘",
                            sideLabels: [(55, "Cmd ⌘"), (54, "Right Cmd ⌘")]),
        ModifierDisplaySpec(modifier: .control, genericLabel: "Ctrl ⌃",
                            sideLabels: [(59, "Ctrl ⌃"), (62, "Right Ctrl ⌃")]),
        ModifierDisplaySpec(modifier: .option, genericLabel: "Option ⌥",
                            sideLabels: [(58, "Option ⌥"), (61, "Right Option ⌥")]),
        ModifierDisplaySpec(modifier: .shift, genericLabel: "Shift ⇧",
                            sideLabels: [(56, "Shift ⇧"), (60, "Right Shift ⇧")]),
        ModifierDisplaySpec(modifier: .function, genericLabel: "Fn 🌐",
                            sideLabels: [(63, "Fn 🌐")])
    ]

    static func modifierDisplayNames(for modifiers: ShortcutModifiers,
                                     exactModifierKeyCodes: Set<UInt16>?) -> [String] {
        var names: [String] = []
        for spec in modifierDisplaySpecs {
            guard modifiers.contains(spec.modifier) else { continue }
            var label = spec.genericLabel
            if let exact = exactModifierKeyCodes {
                for side in spec.sideLabels where exact.contains(side.code) {
                    label = side.label
                    break
                }
            }
            names.append(label)
        }
        return names
    }
}
