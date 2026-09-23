import Foundation

@MainActor
final class VocabularyNotificationManager: ObservableObject, @unchecked Sendable {
    static let shared = VocabularyNotificationManager()

    @Published var showCheckmark = false

    private var flashTask: Task<Void, Never>?

    private init() {}

    func flashCheckmark() {
        flashTask?.cancel()
        showCheckmark = true
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.showCheckmark = false
        }
    }
}
