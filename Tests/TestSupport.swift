import Foundation

enum TestSupport {
    static func expect(_ condition: @autoclosure () -> Bool,
                       _ message: String,
                       file: StaticString = #filePath,
                       line: UInt = #line) {
        guard condition() else {
            fatalError("\(file):\(line): \(message)")
        }
    }

    static func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T,
                                          _ expected: @autoclosure () throws -> T,
                                          _ message: String = "",
                                          file: StaticString = #filePath,
                                          line: UInt = #line) rethrows {
        let actualValue = try actual()
        let expectedValue = try expected()
        guard actualValue == expectedValue else {
            fatalError("\(file):\(line): Expected \(expectedValue), got \(actualValue)\(suffix(message))")
        }
    }

    static func expectApproximatelyEqual(_ actual: Double,
                                         _ expected: Double,
                                         accuracy: Double = 0.000_001,
                                         _ message: String = "",
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        guard abs(actual - expected) <= accuracy else {
            fatalError("\(file):\(line): Expected \(expected) ± \(accuracy), got \(actual)\(suffix(message))")
        }
    }

    static func expectThrows<T>(_ body: @autoclosure () throws -> T,
                                _ message: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        do {
            _ = try body()
            expect(false, message, file: file, line: line)
        } catch {
            // Expected failure.
        }
    }

    private static func suffix(_ message: String) -> String {
        message.isEmpty ? "" : " — \(message)"
    }
}

// Unqualified wrappers so suites call the asserts directly.
func expect(_ condition: @autoclosure () -> Bool,
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line) {
    TestSupport.expect(condition(), message, file: file, line: line)
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T,
                               _ expected: @autoclosure () throws -> T,
                               _ message: String = "",
                               file: StaticString = #filePath,
                               line: UInt = #line) rethrows {
    try TestSupport.expectEqual(actual(), expected(), message, file: file, line: line)
}

func expectApproximatelyEqual(_ actual: Double,
                              _ expected: Double,
                              accuracy: Double = 0.000_001,
                              _ message: String = "",
                              file: StaticString = #filePath,
                              line: UInt = #line) {
    TestSupport.expectApproximatelyEqual(actual,
                                         expected,
                                         accuracy: accuracy,
                                         message,
                                         file: file,
                                         line: line)
}

func expectThrows<T>(_ body: @autoclosure () throws -> T,
                     _ message: String,
                     file: StaticString = #filePath,
                     line: UInt = #line) {
    do {
        _ = try body()
        TestSupport.expect(false, message, file: file, line: line)
    } catch {
        // Expected failure.
    }
}
