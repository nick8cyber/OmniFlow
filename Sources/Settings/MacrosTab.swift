import SwiftUI

// Voice Macros tab: predefined text pasted instantly when the dictation
// matches a command, bypassing post-processing.

struct VoiceMacrosSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editingMacro: VoiceMacro?
    @State private var showsEditor = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard(title: "Voice Macros", icon: "music.mic",
                             subtitle: "Say the command — paste predefined text instantly, no cleanup") {
                    VStack(spacing: 10) {
                        HStack {
                            Spacer()
                            Button("Add Macro") {
                                editingMacro = nil
                                showsEditor = true
                            }
                        }
                        if appState.voiceMacros.isEmpty {
                            EmptyStateView(icon: "music.mic",
                                           title: "No Voice Macros Yet",
                                           hint: "Click 'Add Macro' to define your first voice macro.")
                        } else {
                            VStack(spacing: 8) {
                                ForEach(appState.voiceMacros) { macro in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(macro.command)
                                                .font(.headline)
                                            Text(macro.payload)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Button("Edit") {
                                            editingMacro = macro
                                            showsEditor = true
                                        }
                                        .font(.caption)
                                        Button("Delete") {
                                            appState.voiceMacros.removeAll { $0.id == macro.id }
                                        }
                                        .font(.caption)
                                        .foregroundColor(.red)
                                    }
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showsEditor) {
            VoiceMacroEditorView(macro: editingMacro) { command, payload in
                if let editingMacro {
                    if let index = appState.voiceMacros.firstIndex(where: { $0.id == editingMacro.id }) {
                        appState.voiceMacros[index] = VoiceMacro(id: editingMacro.id,
                                                                 command: command,
                                                                 payload: payload)
                    }
                } else {
                    appState.voiceMacros.append(VoiceMacro(command: command, payload: payload))
                }
            }
        }
    }
}

private struct VoiceMacroEditorView: View {
    let macro: VoiceMacro?
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var payload = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(macro == nil ? "Add Macro" : "Edit Macro")
                .font(.headline)
            TextField("e.g. debugging prompt", text: $command)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $payload)
                .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    onSave(command.trimmingCharacters(in: .whitespacesAndNewlines), payload)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || payload.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            command = macro?.command ?? ""
            payload = macro?.payload ?? ""
        }
    }
}
