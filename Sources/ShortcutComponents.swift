import SwiftUI
import AppKit

struct DictationShortcutEditor: View {
    @EnvironmentObject private var appState: AppState
    var onCaptureStateChange: ((Bool) -> Void)?

    @State private var capturingHold = false
    @State private var capturingToggle = false
    @State private var capturingCopyAgain = false
    @State private var holdValidationMessage: String?
    @State private var toggleValidationMessage: String?
    @State private var copyAgainValidationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hold to record, tap to start and stop, and press the toggle shortcut while holding to latch into tap mode. Paste Again repeats your last transcript at the cursor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !appState.hasEnabledHoldShortcut && !appState.hasEnabledToggleShortcut {
                Label("Both dictation shortcuts are disabled.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            ShortcutRoleSection(role: .hold,
                                selection: appState.holdShortcut,
                                savedBinding: appState.savedCustomShortcut(for: .hold),
                                validationMessage: holdValidationMessage,
                                isCapturing: $capturingHold,
                                onSelect: { select($0, for: .hold) },
                                onCaptureStateChange: captureStateChanged)
            ShortcutRoleSection(role: .toggle,
                                selection: appState.toggleShortcut,
                                savedBinding: appState.savedCustomShortcut(for: .toggle),
                                validationMessage: toggleValidationMessage,
                                isCapturing: $capturingToggle,
                                onSelect: { select($0, for: .toggle) },
                                onCaptureStateChange: captureStateChanged)
            ShortcutRoleSection(role: .copyAgain,
                                selection: appState.copyAgainShortcut,
                                savedBinding: appState.savedCustomShortcut(for: .copyAgain),
                                validationMessage: copyAgainValidationMessage,
                                isCapturing: $capturingCopyAgain,
                                onSelect: { select($0, for: .copyAgain) },
                                onCaptureStateChange: captureStateChanged)
            Text("Custom shortcuts can use regular keys, modifier-only shortcuts, or modifier combinations.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.usesFnShortcut {
                fnAdvice
            }
        }
    }

    private var fnAdvice: some View {
        Label("If pressing your shortcut opens the emoji picker instead, set the Globe/Fn key to \"Do Nothing\" in System Settings > Keyboard > Keyboard Shortcuts > Fn Keys.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(.orange)
    }

    private func select(_ binding: ShortcutBinding, for role: ShortcutRole) {
        let message = appState.setShortcut(binding, for: role)
        switch role {
        case .hold:
            holdValidationMessage = message
        case .toggle:
            toggleValidationMessage = message
        case .copyAgain:
            copyAgainValidationMessage = message
        }
    }

    private func captureStateChanged(_ capturing: Bool) {
        let anyCapturing = capturingHold || capturingToggle || capturingCopyAgain
        onCaptureStateChange?(anyCapturing)
    }
}

struct ShortcutRoleSection: View {
    let role: ShortcutRole
    let selection: ShortcutBinding
    let savedBinding: ShortcutBinding?
    let validationMessage: String?
    @Binding var isCapturing: Bool
    let onSelect: (ShortcutBinding) -> Void
    var onCaptureStateChange: ((Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role.title)
                .font(.headline)
            ShortcutPresetRow(selected: selection.isDisabled,
                              title: "Disabled",
                              onSelect: { onSelect(.disabled) })
            ForEach(ShortcutPreset.allCases) { preset in
                ShortcutPresetRow(selected: selection == preset.binding,
                                  title: preset.title,
                                  onSelect: { onSelect(preset.binding) })
            }
            ShortcutCaptureRow(savedBinding: savedBinding,
                               selection: selection,
                               isCapturing: $isCapturing,
                               onSelect: onSelect,
                               onCaptureStateChange: onCaptureStateChange)
            if let validationMessage, !validationMessage.isEmpty {
                Label(validationMessage, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
}

private struct ShortcutPresetRow: View {
    let selected: Bool
    let title: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .blue : .secondary)
                Text(title)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.blue : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutCaptureRow: View {
    let savedBinding: ShortcutBinding?
    let selection: ShortcutBinding
    @Binding var isCapturing: Bool
    let onSelect: (ShortcutBinding) -> Void
    var onCaptureStateChange: ((Bool) -> Void)?

    @State private var backend = LocalShortcutCaptureBackend()
    @State private var inputState = ShortcutInputState()
    @State private var pendingBinding: ShortcutBinding?

    private let escapeKeyCode: UInt16 = 53
    private let returnKeyCode: UInt16 = 36
    private let keypadReturnKeyCode: UInt16 = 76

    private var isSelected: Bool {
        selection.isCustom
    }

    private var displayedBinding: ShortcutBinding? {
        isCapturing ? pendingBinding : savedBinding
    }

    private var subtitle: String {
        if isCapturing {
            return pendingBinding == nil ? "Recording shortcut…" : "Recorded shortcut"
        }
        return savedBinding == nil ? "Record any key combo." : "Saved custom shortcut"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayedBinding?.displayName ?? "Custom Shortcut")
                        .font(displayedBinding == nil ? Font.body.weight(.regular) : Font.body.monospaced().weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCapturing {
                    Button("Cancel") {
                        pendingBinding = nil
                        isCapturing = false
                    }
                    .buttonStyle(.plain)
                    Button("Done") {
                        finishCapture()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Record…") {
                        isCapturing = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5))
            if isCapturing {
                Label(pendingBinding == nil ? "Press and hold the shortcut you want." : "Press Esc or Enter to save.",
                      systemImage: "keyboard")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .onAppear(perform: installHandlers)
        .onChange(of: isCapturing) { capturing in
            if capturing {
                startCapture()
            } else {
                backend.stop()
                onCaptureStateChange?(false)
            }
        }
        .onDisappear {
            backend.stop()
            pendingBinding = nil
            onCaptureStateChange?(false)
        }
    }

    private var iconName: String {
        if isSelected {
            return "checkmark.circle.fill"
        }
        return savedBinding == nil ? "plus.circle" : "circle"
    }

    private var iconColor: Color {
        isSelected ? .blue : .secondary
    }

    private func installHandlers() {
        backend.onInputEvent = { event in
            handleInput(event)
        }
        backend.onKeyDownEvent = { event in
            handleKeyDown(event)
        }
    }

    private func startCapture() {
        pendingBinding = nil
        inputState = ShortcutInputState()
        backend.start()
        onCaptureStateChange?(true)
    }

    // The confirmed behavior (spec 23 §9): a pending binding is confirmed by
    // Esc; with no pending binding Esc itself becomes the recorded binding.
    // isRepeat events are ignored.
    private func handleKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        switch event.keyCode {
        case returnKeyCode, keypadReturnKeyCode:
            finishCapture()
        case escapeKeyCode:
            if pendingBinding != nil {
                finishCapture()
            } else if let binding = ShortcutBinding.from(event: event,
                                                          pressedModifierKeyCodes: inputState.pressedModifierKeyCodes) {
                pendingBinding = binding
            }
        default:
            if let binding = ShortcutBinding.from(event: event,
                                                  pressedModifierKeyCodes: inputState.pressedModifierKeyCodes) {
                pendingBinding = binding
            }
        }
    }

    private func handleInput(_ event: ShortcutInputEvent) {
        let result = ShortcutMatcher.reduce(state: inputState, event: event, configuration: .disabled)
        inputState = result.state
        if case .modifierChanged(let keyCode, let isDown) = event {
            guard isDown else { return }
            if let binding = ShortcutBinding.fromModifierKeyCode(keyCode,
                                                                 pressedModifierKeyCodes: result.state.pressedModifierKeyCodes,
                                                                 allowBareModifier: true) {
                pendingBinding = binding
            }
        }
    }

    private func finishCapture() {
        if let binding = pendingBinding {
            onSelect(binding)
        }
        pendingBinding = nil
        isCapturing = false
    }
}
