import Foundation

enum AppName {
    static let displayName: String = {
        let name = Bundle.main.infoDictionary?["CFBundleName"] as? String
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return "OmniFlow"
    }()
}
