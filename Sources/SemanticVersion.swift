import Foundation

struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ value: String) {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let plusIndex = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[trimmed.startIndex..<plusIndex])
        }
        let coreAndPrerelease = trimmed.split(separator: "-",
                                              maxSplits: 1,
                                              omittingEmptySubsequences: false)
        guard !coreAndPrerelease.isEmpty, coreAndPrerelease.count <= 2 else { return nil }
        let coreComponents = coreAndPrerelease[0].split(separator: ".",
                                                        omittingEmptySubsequences: false)
        guard coreComponents.count == 3 else { return nil }
        var numbers: [Int] = []
        for component in coreComponents {
            guard !component.isEmpty, let number = Int(component) else { return nil }
            numbers.append(number)
        }
        var identifiers: [String] = []
        if coreAndPrerelease.count == 2 {
            let prereleaseString = coreAndPrerelease[1]
            guard !prereleaseString.isEmpty else { return nil }
            for component in prereleaseString.split(separator: ".",
                                                    omittingEmptySubsequences: false) {
                guard !component.isEmpty else { return nil }
                identifiers.append(String(component))
            }
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        prerelease = identifiers
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            // A prerelease is older than the stable release of the same core version.
            return !lhs.prerelease.isEmpty
        }
        guard !lhs.prerelease.isEmpty else { return false }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case (let a?, let b?):
                return a < b
            case (_?, nil):
                // Numeric identifiers always have lower precedence than alphanumeric.
                return true
            case (nil, _?):
                return false
            default:
                return left < right
            }
        }
        // All shared identifiers equal: the shorter prerelease list is older.
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
