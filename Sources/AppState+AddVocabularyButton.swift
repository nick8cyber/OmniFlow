import AppKit

@MainActor
extension AppState {
    @discardableResult
    func pasteWordToVocabulary() -> String? {
        guard let pasteboardText = NSPasteboard.general.string(forType: .string) else { return nil }
        let separators = CharacterSet(charactersIn: "\n,;")
        let incomingWords = pasteboardText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !incomingWords.isEmpty else { return nil }

        let existingTerms = customVocabulary
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lowercasedExisting = Set(existingTerms.map { $0.lowercased() })

        let newWords = incomingWords.filter { !lowercasedExisting.contains($0.lowercased()) }
        guard !newWords.isEmpty else { return nil }

        var updated = customVocabulary
        if !updated.isEmpty && !updated.hasSuffix("\n") && !updated.hasSuffix(",") {
            updated += ","
        }
        if !updated.isEmpty && !updated.hasSuffix("\n") {
            updated += "\n"
        }
        customVocabulary = updated + newWords.joined(separator: ", ")
        return newWords.joined(separator: ", ")
    }
}
