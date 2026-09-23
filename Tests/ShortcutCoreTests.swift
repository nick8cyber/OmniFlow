import Foundation

enum ShortcutCoreTests {
    static func run() {
        testBareFnHoldLifecycle()
        testDefaultShortcutSpecificityOrdering()
        testRightOptionPresetIsSideSpecific()
        testExactModifierMatching()
        testReducerHonorsExactModifierMatching()
        testRepeatedKeyDownDoesNotReactivate()
        testPasteAgainFiresOnLeadingEdgeOnly()
        testBackendResetClearsActiveBindings()
        testBindingMigrationAndIdentity()
        testConflictDetection()
        testHoldSessionControllerLifecycle()
        testToggleSessionControllerLifecycle()
        testHoldToToggleSessionControllerLifecycle()
    }

    // Key codes used below: 63 Fn, 61 Right Option, 58 Left Option,
    // 55 Left Command, 54 Right Command, 56 Left Shift, 96 F5.

    private static func reduce(_ state: ShortcutInputState,
                               _ event: ShortcutInputEvent,
                               _ configuration: ShortcutConfiguration) -> ShortcutMatchResult {
        ShortcutMatcher.reduce(state: state, event: event, configuration: configuration)
    }

    // MARK: - 1

    private static func testBareFnHoldLifecycle() {
        let configuration = ShortcutConfiguration(hold: ShortcutPreset.fnKey.binding,
                                                  toggle: .disabled,
                                                  copyAgain: .disabled)
        let down = reduce(ShortcutInputState(), .modifierChanged(keyCode: 63, isDown: true), configuration)
        expectEqual(down.emittedEvents, [.holdActivated], "Fn down must emit holdActivated")
        expectEqual(down.consumeDecision, .consume, "Fn down must be consumed")
        expect(down.state.holdIsActive, "hold must be active after Fn down")

        let up = reduce(down.state, .modifierChanged(keyCode: 63, isDown: false), configuration)
        expectEqual(up.emittedEvents, [.holdDeactivated], "Fn up must emit holdDeactivated")
        expectEqual(up.consumeDecision, .consume, "Fn up must be consumed")
        expect(!up.state.holdIsActive, "hold must be inactive after Fn up")
    }

    // MARK: - 2

    private static func testDefaultShortcutSpecificityOrdering() {
        let configuration = ShortcutConfiguration(hold: .defaultHold, toggle: .defaultToggle)
        var state = ShortcutInputState()

        let commandDown = reduce(state, .modifierChanged(keyCode: 55, isDown: true), configuration)
        expectEqual(commandDown.emittedEvents, [] as [ShortcutEvent],
                    "Left Command alone must not trigger anything")
        state = commandDown.state

        let fnDown = reduce(state, .modifierChanged(keyCode: 63, isDown: true), configuration)
        expectEqual(fnDown.emittedEvents, [.toggleActivated, .holdActivated],
                    "toggle (more specific) must activate before hold")
        state = fnDown.state
        expect(state.holdIsActive && state.toggleIsActive, "hold and toggle must both be active")

        let fnUp = reduce(state, .modifierChanged(keyCode: 63, isDown: false), configuration)
        expectEqual(fnUp.emittedEvents, [.holdDeactivated, .toggleDeactivated],
                    "deactivations must be emitted in ascending specificity order")
        expect(!fnUp.state.holdIsActive && !fnUp.state.toggleIsActive, "nothing active after Fn up")
    }

    // MARK: - 3

    private static func testRightOptionPresetIsSideSpecific() {
        let configuration = ShortcutConfiguration(hold: ShortcutPreset.rightOption.binding,
                                                  toggle: .disabled,
                                                  copyAgain: .disabled)
        var state = ShortcutInputState()

        let leftDown = reduce(state, .modifierChanged(keyCode: 58, isDown: true), configuration)
        expectEqual(leftDown.emittedEvents, [] as [ShortcutEvent],
                    "Left Option must not trigger the Right Option shortcut")
        expectEqual(leftDown.consumeDecision, .passthrough, "Left Option must pass through")
        state = leftDown.state

        let leftUp = reduce(state, .modifierChanged(keyCode: 58, isDown: false), configuration)
        state = leftUp.state

        let rightDown = reduce(state, .modifierChanged(keyCode: 61, isDown: true), configuration)
        expectEqual(rightDown.emittedEvents, [.holdActivated], "Right Option must trigger hold")
        expectEqual(rightDown.consumeDecision, .consume, "Right Option must be consumed")
    }

    // MARK: - 4

    private static func testExactModifierMatching() {
        expect(ShortcutBinding.exactModifierKeyCodesMatch([54], exactModifierKeyCodes: [54, 55]),
               "generic Command exact match must accept Right Command")
        expect(ShortcutBinding.exactModifierKeyCodesMatch([55], exactModifierKeyCodes: [54, 55]),
               "generic Command exact match must accept Left Command")
        expect(!ShortcutBinding.exactModifierKeyCodesMatch([55, 56], exactModifierKeyCodes: [55]),
               "extra Shift must invalidate exact [55]")
        expect(ShortcutBinding.exactModifierKeyCodesMatch([55, 56],
                                                          exactModifierKeyCodes: [55],
                                                          permittedAdditionalExactMatchModifiers: [.shift]),
               "permitted additional Shift must keep exact [55] valid")
    }

    // MARK: - 5

    private static func testReducerHonorsExactModifierMatching() {
        let hold = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [.command],
                                   kind: .key, preset: nil, exactModifierKeyCodes: [55])
        let configuration = ShortcutConfiguration(hold: hold, toggle: .disabled, copyAgain: .disabled)
        var state = ShortcutInputState()

        let rightCommandDown = reduce(state, .modifierChanged(keyCode: 54, isDown: true), configuration)
        state = rightCommandDown.state
        let f5WithRightCommand = reduce(state, .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
                                        configuration)
        expectEqual(f5WithRightCommand.emittedEvents, [] as [ShortcutEvent],
                    "Right Command + F5 must not match exact [55]")
        state = f5WithRightCommand.state
        state = reduce(state, .keyChanged(keyCode: 96, isDown: false, isRepeat: false), configuration).state
        state = reduce(state, .modifierChanged(keyCode: 54, isDown: false), configuration).state

        let leftCommandDown = reduce(state, .modifierChanged(keyCode: 55, isDown: true), configuration)
        state = leftCommandDown.state
        let f5WithLeftCommand = reduce(state, .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
                                       configuration)
        expectEqual(f5WithLeftCommand.emittedEvents, [.holdActivated],
                    "Left Command + F5 must match exact [55]")
        state = f5WithLeftCommand.state

        let shiftDown = reduce(state, .modifierChanged(keyCode: 56, isDown: true), configuration)
        expectEqual(shiftDown.emittedEvents, [.holdDeactivated],
                    "added Shift must invalidate the exact match")

        let permittedConfiguration = ShortcutConfiguration(hold: hold, toggle: .disabled,
                                                           copyAgain: .disabled,
                                                           permittedAdditionalExactMatchModifiers: [.shift])
        let recheck = reduce(shiftDown.state, .modifierSnapshot([55, 56]), permittedConfiguration)
        expectEqual(recheck.emittedEvents, [.holdActivated],
                    "permitted additional Shift must keep the binding active")
    }

    // MARK: - 6

    private static func testRepeatedKeyDownDoesNotReactivate() {
        let hold = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [],
                                   kind: .key, preset: nil, exactModifierKeyCodes: nil)
        let configuration = ShortcutConfiguration(hold: hold, toggle: .disabled, copyAgain: .disabled)
        let down = reduce(ShortcutInputState(), .keyChanged(keyCode: 96, isDown: true, isRepeat: false),
                          configuration)
        expectEqual(down.emittedEvents, [.holdActivated], "first press must activate hold")

        let repeated = reduce(down.state, .keyChanged(keyCode: 96, isDown: true, isRepeat: true),
                              configuration)
        expectEqual(repeated.emittedEvents, [] as [ShortcutEvent], "auto-repeat must emit nothing")
        expectEqual(repeated.state, down.state, "auto-repeat must not change state")
        expectEqual(repeated.consumeDecision, .consume, "auto-repeat of a matching key must be consumed")
    }

    // MARK: - 7

    private static func testPasteAgainFiresOnLeadingEdgeOnly() {
        let copyAgain = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [],
                                        kind: .key, preset: nil, exactModifierKeyCodes: nil)
        let configuration = ShortcutConfiguration(hold: .disabled, toggle: .disabled, copyAgain: copyAgain)
        var state = ShortcutInputState()

        let firstDown = reduce(state, .keyChanged(keyCode: 96, isDown: true, isRepeat: false), configuration)
        expectEqual(firstDown.emittedEvents, [.copyAgainTriggered], "first press must fire Paste Again")
        state = firstDown.state

        let repeated = reduce(state, .keyChanged(keyCode: 96, isDown: true, isRepeat: true), configuration)
        expectEqual(repeated.emittedEvents, [] as [ShortcutEvent], "repeat must not refire Paste Again")
        state = repeated.state

        let up = reduce(state, .keyChanged(keyCode: 96, isDown: false, isRepeat: false), configuration)
        expectEqual(up.emittedEvents, [] as [ShortcutEvent], "release must not fire Paste Again")
        expect(!up.state.copyAgainIsActive, "Paste Again must be inactive after release")
        state = up.state

        let secondDown = reduce(state, .keyChanged(keyCode: 96, isDown: true, isRepeat: false), configuration)
        expectEqual(secondDown.emittedEvents, [.copyAgainTriggered], "second press must fire again")
    }

    // MARK: - 8

    private static func testBackendResetClearsActiveBindings() {
        let configuration = ShortcutConfiguration(hold: .defaultHold, toggle: .defaultToggle)
        var state = ShortcutInputState()
        state = reduce(state, .modifierChanged(keyCode: 55, isDown: true), configuration).state
        state = reduce(state, .modifierChanged(keyCode: 63, isDown: true), configuration).state
        expect(state.holdIsActive && state.toggleIsActive, "hold and toggle must be active before reset")

        let reset = reduce(state, .backendReset, configuration)
        expectEqual(reset.emittedEvents, [.holdDeactivated, .toggleDeactivated],
                    "reset must deactivate active bindings in ascending order")
        expectEqual(reset.consumeDecision, .passthrough, "reset must always pass through")
        expect(reset.state.pressedKeyCodes.isEmpty, "reset must clear pressed key codes")
        expect(reset.state.pressedModifierKeyCodes.isEmpty, "reset must clear pressed modifier codes")
        expect(!reset.state.holdIsActive && !reset.state.toggleIsActive,
               "reset must deactivate hold and toggle")
    }

    // MARK: - 9

    private static func testBindingMigrationAndIdentity() {
        let binding = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [],
                                      kind: .key, preset: nil, exactModifierKeyCodes: [999, 61])
        let normalized = binding.normalizedForStorageMigration()
        expectEqual(normalized.exactModifierKeyCodes, Set<UInt16>([61]),
                    "invalid modifier codes must be dropped during migration")
        expectEqual(normalized.modifiers, ShortcutModifiers.option,
                    "Option must be inferred from the surviving exact code")

        let first = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [.command, .option],
                                    kind: .key, preset: nil, exactModifierKeyCodes: [55, 58])
        let second = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [.option, .command],
                                     kind: .key, preset: nil, exactModifierKeyCodes: [58, 55])
        expectEqual(first.id, second.id,
                    "id must not depend on modifier or exact-code ordering")
    }

    // MARK: - 10

    private static func testConflictDetection() {
        let f5 = ShortcutBinding(keyCode: 96, keyDisplay: "F5", modifiers: [],
                                 kind: .key, preset: nil, exactModifierKeyCodes: nil)
        expect(f5.conflicts(with: f5), "identical bindings must conflict")
        expect(f5.conflicts(with: f5), "conflict detection must be symmetric")

        let f6 = ShortcutBinding(keyCode: 97, keyDisplay: "F6", modifiers: [],
                                 kind: .key, preset: nil, exactModifierKeyCodes: nil)
        expect(!f5.conflicts(with: f6), "different primary keys must not conflict")
        expect(!f6.conflicts(with: f5), "conflict detection must be symmetric")

        expect(!f5.conflicts(with: .disabled), "disabled bindings must never conflict")
        expect(!ShortcutBinding.disabled.conflicts(with: f5), "disabled bindings must never conflict")
    }

    // MARK: - 11

    private static func testHoldSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        expectEqual(controller.handle(event: .holdActivated, isTranscribing: true),
                    nil as DictationShortcutAction?,
                    "no session may start while transcribing")
        expectEqual(controller.handle(event: .holdActivated, isTranscribing: false),
                    .start(.hold), "hold activation must start a hold session")
        expectEqual(controller.activeMode, .some(.hold), "active mode must be hold")
        expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false),
                    .stop, "hold release must stop the session")
        expectEqual(controller.activeMode, nil as RecordingTriggerMode?,
                    "session must be reset after stop")
    }

    // MARK: - 12

    private static func testToggleSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false),
                    .start(.toggle), "first activation must start a toggle session")
        expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false),
                    nil as DictationShortcutAction?,
                    "second activation without release must be ignored")
        expectEqual(controller.handle(event: .toggleDeactivated, isTranscribing: false),
                    nil as DictationShortcutAction?, "release must only arm the stop")
        expect(controller.toggleStopArmed, "toggle stop must be armed after release")
        expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false),
                    .stop, "armed second press must stop the session")
        expectEqual(controller.activeMode, nil as RecordingTriggerMode?,
                    "session must be reset after stop")
    }

    // MARK: - 13

    private static func testHoldToToggleSessionControllerLifecycle() {
        let controller = DictationShortcutSessionController()
        expectEqual(controller.handle(event: .holdActivated, isTranscribing: false),
                    .start(.hold), "hold activation must start a hold session")
        expectEqual(controller.handle(event: .toggleActivated, isTranscribing: false),
                    .switchedToToggle, "toggle activation during hold must switch mode")
        expectEqual(controller.activeMode, .some(.toggle), "mode must be toggle after switch")
        expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false),
                    nil as DictationShortcutAction?,
                    "hold release must not end the toggle session")
        expectEqual(controller.activeMode, .some(.toggle), "toggle session must survive hold release")
        expectEqual(controller.handle(event: .copyAgainTriggered, isTranscribing: false),
                    nil as DictationShortcutAction?, "copy again must never reach the controller")

        controller.beginManual(mode: .hold)
        expectEqual(controller.activeMode, .some(.hold), "beginManual must set hold mode")
        controller.forceToggleMode()
        expectEqual(controller.activeMode, .some(.toggle), "forceToggleMode must set toggle mode")
        controller.reset()
        expectEqual(controller.activeMode, nil as RecordingTriggerMode?, "reset must clear the mode")
        expect(!controller.toggleStopArmed, "reset must clear the armed flag")
    }
}
