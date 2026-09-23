import Foundation

enum ShortcutInputEvent: Equatable {
    case modifierChanged(keyCode: UInt16, isDown: Bool)
    case modifierSnapshot(Set<UInt16>)
    case keyChanged(keyCode: UInt16, isDown: Bool, isRepeat: Bool)
    case backendReset
}

enum ShortcutConsumeDecision: Equatable {
    case consume, passthrough
}

struct ShortcutInputState: Equatable {
    var pressedKeyCodes: Set<UInt16> = []
    var pressedModifierKeyCodes: Set<UInt16> = []
    var holdIsActive = false
    var toggleIsActive = false
    var copyAgainIsActive = false

    init() {}

    var currentModifiers: ShortcutModifiers {
        ShortcutBinding.modifiers(for: pressedModifierKeyCodes)
    }

    func hasPressedShortcutInputs(configuration: ShortcutConfiguration) -> Bool {
        let bindings = [configuration.hold, configuration.toggle, configuration.copyAgain]
        for binding in bindings where binding.kind == .key && pressedKeyCodes.contains(binding.keyCode) {
            return true
        }
        let permittedCodes = ShortcutBinding.matchingModifierKeyCodes(
            for: configuration.permittedAdditionalExactMatchModifiers)
        for binding in bindings {
            guard !binding.isDisabled else { continue }
            let referencesModifiers: Bool
            if let exact = binding.exactModifierKeyCodes {
                referencesModifiers = !exact.isDisjoint(with: pressedModifierKeyCodes)
                    || !permittedCodes.isDisjoint(with: pressedModifierKeyCodes)
            } else {
                referencesModifiers = !binding.modifiers.intersection(currentModifiers).isEmpty
            }
            guard referencesModifiers else { continue }
            if binding.kind == .modifierKey {
                if pressedModifierKeyCodes.contains(binding.keyCode) {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }
}

struct ShortcutMatchResult: Equatable {
    let state: ShortcutInputState
    let emittedEvents: [ShortcutEvent]
    let consumeDecision: ShortcutConsumeDecision
}

enum ShortcutMatcher {
    static func reduce(state: ShortcutInputState,
                       event: ShortcutInputEvent,
                       configuration: ShortcutConfiguration) -> ShortcutMatchResult {
        var nextState = state

        switch event {
        case .backendReset:
            nextState.pressedKeyCodes = []
            nextState.pressedModifierKeyCodes = []
            updateActiveBindings(&nextState, configuration: configuration)
            let emitted = emitChanges(previous: state, current: nextState, configuration: configuration)
            return ShortcutMatchResult(state: nextState,
                                       emittedEvents: emitted,
                                       consumeDecision: .passthrough)

        case .modifierSnapshot(let codes):
            nextState.pressedModifierKeyCodes = codes
            updateActiveBindings(&nextState, configuration: configuration)
            let emitted = emitChanges(previous: state, current: nextState, configuration: configuration)
            return ShortcutMatchResult(state: nextState,
                                       emittedEvents: emitted,
                                       consumeDecision: emitted.isEmpty ? .passthrough : .consume)

        case .modifierChanged(let keyCode, let isDown):
            let shouldConsumeBefore = shouldConsumeModifierEvent(keyCode,
                                                                 state: state,
                                                                 configuration: configuration)
            if isDown {
                nextState.pressedModifierKeyCodes.insert(keyCode)
            } else {
                nextState.pressedModifierKeyCodes.remove(keyCode)
            }
            let shouldConsumeAfter = shouldConsumeModifierEvent(keyCode,
                                                                state: nextState,
                                                                configuration: configuration)
            updateActiveBindings(&nextState, configuration: configuration)
            let emitted = emitChanges(previous: state, current: nextState, configuration: configuration)
            return ShortcutMatchResult(state: nextState,
                                       emittedEvents: emitted,
                                       consumeDecision: (shouldConsumeBefore || shouldConsumeAfter)
                                           ? .consume : .passthrough)

        case .keyChanged(let keyCode, let isDown, let isRepeat):
            let shouldConsumeBefore = shouldConsumeKeyEvent(keyCode,
                                                            state: state,
                                                            configuration: configuration)
            if isRepeat {
                return ShortcutMatchResult(state: state,
                                           emittedEvents: [],
                                           consumeDecision: shouldConsumeBefore ? .consume : .passthrough)
            }
            if isDown {
                nextState.pressedKeyCodes.insert(keyCode)
            } else {
                nextState.pressedKeyCodes.remove(keyCode)
            }
            let shouldConsumeAfter = shouldConsumeKeyEvent(keyCode,
                                                           state: nextState,
                                                           configuration: configuration)
            updateActiveBindings(&nextState, configuration: configuration)
            let emitted = emitChanges(previous: state, current: nextState, configuration: configuration)
            return ShortcutMatchResult(state: nextState,
                                       emittedEvents: emitted,
                                       consumeDecision: (shouldConsumeBefore || shouldConsumeAfter)
                                           ? .consume : .passthrough)
        }
    }

    // MARK: - Activity evaluation

    private static func updateActiveBindings(_ state: inout ShortcutInputState,
                                             configuration: ShortcutConfiguration) {
        state.holdIsActive = bindingIsActive(configuration.hold, state: state, configuration: configuration)
        state.toggleIsActive = bindingIsActive(configuration.toggle, state: state, configuration: configuration)
        state.copyAgainIsActive = bindingIsActive(configuration.copyAgain, state: state, configuration: configuration)
    }

    private static func bindingIsActive(_ binding: ShortcutBinding,
                                        state: ShortcutInputState,
                                        configuration: ShortcutConfiguration) -> Bool {
        guard !binding.isDisabled else { return false }
        guard state.currentModifiers.isSuperset(of: binding.modifiers) else { return false }
        if let exact = binding.exactModifierKeyCodes,
           !ShortcutBinding.exactModifierKeyCodesMatch(state.pressedModifierKeyCodes,
                                                       exactModifierKeyCodes: exact,
                                                       permittedAdditionalExactMatchModifiers:
                                                           configuration.permittedAdditionalExactMatchModifiers) {
            return false
        }
        switch binding.kind {
        case .key:
            return state.pressedKeyCodes.contains(binding.keyCode)
        case .modifierKey:
            return state.pressedModifierKeyCodes.contains(binding.keyCode)
        case .disabled:
            return false
        }
    }

    // MARK: - Event emission

    private static func emitChanges(previous: ShortcutInputState,
                                    current: ShortcutInputState,
                                    configuration: ShortcutConfiguration) -> [ShortcutEvent] {
        var activations: [(event: ShortcutEvent, score: Int)] = []
        var deactivations: [(event: ShortcutEvent, score: Int)] = []

        if current.holdIsActive, !previous.holdIsActive {
            activations.append((.holdActivated, configuration.hold.specificityScore))
        } else if !current.holdIsActive, previous.holdIsActive {
            deactivations.append((.holdDeactivated, configuration.hold.specificityScore))
        }
        if current.toggleIsActive, !previous.toggleIsActive {
            activations.append((.toggleActivated, configuration.toggle.specificityScore))
        } else if !current.toggleIsActive, previous.toggleIsActive {
            deactivations.append((.toggleDeactivated, configuration.toggle.specificityScore))
        }
        // copyAgain fires on the leading edge only; release never emits.
        if current.copyAgainIsActive, !previous.copyAgainIsActive {
            activations.append((.copyAgainTriggered, configuration.copyAgain.specificityScore))
        }

        activations.sort { $0.score > $1.score }
        deactivations.sort { $0.score < $1.score }
        return activations.map(\.event) + deactivations.map(\.event)
    }

    // MARK: - Consume decisions

    private static func shouldConsumeModifierEvent(_ keyCode: UInt16,
                                                   state: ShortcutInputState,
                                                   configuration: ShortcutConfiguration) -> Bool {
        for binding in [configuration.hold, configuration.toggle, configuration.copyAgain] {
            guard modifierEventRelevantToBinding(keyCode, binding: binding) else { continue }
            if bindingIsActive(binding, state: state, configuration: configuration) {
                return true
            }
        }
        return false
    }

    private static func modifierEventRelevantToBinding(_ keyCode: UInt16,
                                                       binding: ShortcutBinding) -> Bool {
        guard !binding.isDisabled else { return false }
        if binding.keyCode == keyCode { return true }
        guard binding.kind == .key || binding.kind == .modifierKey else { return false }
        guard let logical = ShortcutBinding.logicalModifier(forKeyCode: keyCode) else { return false }
        if binding.exactModifierKeyCodes != nil { return true }
        return binding.modifiers.contains(logical)
    }

    private static func shouldConsumeKeyEvent(_ keyCode: UInt16,
                                              state: ShortcutInputState,
                                              configuration: ShortcutConfiguration) -> Bool {
        [configuration.hold, configuration.toggle, configuration.copyAgain].contains { binding in
            binding.kind == .key
                && binding.keyCode == keyCode
                && bindingIsActive(binding, state: state, configuration: configuration)
        }
    }
}
