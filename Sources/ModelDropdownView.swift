import SwiftUI

struct ModelDropdownView: View {
    let title: String
    var subtitle: String?
    let predefinedModels: [String]
    let defaultModel: String
    @Binding var textDraft: String
    var onCommit: () -> Void
    var onReset: () -> Void

    @State private var isCustom = false
    @FocusState private var customFieldFocused: Bool

    private var selectionBinding: Binding<String> {
        Binding<String>(
            get: { isCustom ? "__custom__" : textDraft },
            set: { newValue in
                if newValue == "__custom__" {
                    if !isCustom {
                        isCustom = true
                        if predefinedModels.contains(textDraft) {
                            textDraft = ""
                        }
                    }
                } else {
                    isCustom = false
                    textDraft = newValue
                    onCommit()
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                Picker("", selection: selectionBinding) {
                    ForEach(predefinedModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    Divider()
                    Text("Custom...").tag("__custom__")
                }
                .labelsHidden()
                if isCustom {
                    TextField(defaultModel, text: $textDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small)))
                        .focused($customFieldFocused)
                        .onSubmit {
                            commitCustom()
                        }
                        .onExitCommand {
                            commitCustom()
                        }
                }
                Button("Reset to Default") {
                    isCustom = false
                    onReset()
                }
                .font(.caption)
            }
            if isCustom {
                Text("Custom model ID — used verbatim in API requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            syncCustomState()
        }
        .onChange(of: textDraft) { _ in
            syncCustomState()
        }
        .onChange(of: customFieldFocused) { focused in
            if !focused {
                commitCustom()
            }
        }
    }

    /// Committing an empty custom field used to store an empty model ID that
    /// only surfaced as an HTTP 400 during dictation; reset to the default
    /// model instead.
    private func commitCustom() {
        guard !textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isCustom = false
            onReset()
            return
        }
        onCommit()
    }

    private func syncCustomState() {
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !predefinedModels.contains(trimmed) {
            isCustom = true
        }
    }
}
