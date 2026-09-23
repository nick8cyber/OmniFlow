import Foundation

enum SemanticVersionTests {
    static func run() {
        testParsingAndBuildMetadata()
        testCoreVersionOrdering()
        testOfficialPrereleaseOrdering()
        testInvalidVersionsAreRejected()
    }

    private static func version(_ value: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) -> SemanticVersion {
        guard let parsed = SemanticVersion(value) else {
            fatalError("\(file):\(line): Expected \"\(value)\" to parse as SemanticVersion")
        }
        return parsed
    }

    // MARK: - 1

    private static func testParsingAndBuildMetadata() {
        expectEqual(version(" v1.2.3 "), version("V1.2.3"),
                    "trim and case of the v-prefix must not matter")
        expectEqual(version("1.2.3+build.1"), version("1.2.3+build.2"),
                    "build metadata must not affect equality")
        expect(version("1.2.3-alpha") < version("1.2.3"),
               "prerelease is older than the stable release")
        expect(version("1.2.3-1") < version("1.2.3-alpha"),
               "numeric prerelease identifier is older than an alphanumeric one")
        expect(version("1.2.3-alpha") < version("1.2.3-alpha.1"),
               "shorter prerelease list is older")
    }

    // MARK: - 2

    private static func testCoreVersionOrdering() {
        expect(version("1.2.3") < version("1.2.4"), "patch ordering")
        expect(version("1.2.9") < version("1.3.0"), "minor ordering")
        expect(version("1.9.9") < version("2.0.0"), "major ordering")
    }

    // MARK: - 3

    private static func testOfficialPrereleaseOrdering() {
        let chain = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0"
        ]
        for (older, newer) in zip(chain, chain.dropFirst()) {
            expect(version(older) < version(newer),
                   "semver 2.0 ordering violated: \(older) must be older than \(newer)")
        }
    }

    // MARK: - 4

    private static func testInvalidVersionsAreRejected() {
        for invalid in ["", "1.2", "1.2.3.4", "one.2.3", "1.2.3-", "1.2.3-alpha..1"] {
            expect(SemanticVersion(invalid) == nil,
                   "\"\(invalid)\" must be rejected as a SemanticVersion")
        }
    }
}
