import Foundation

enum OverlayTextFitterTests {
    // Fake measurer: 40 characters wrap to one line (monotone in length).
    private static let charsPerLine = 40
    private static let lineHeight: CGFloat = 16
    private static func measure(_ text: String) -> CGFloat {
        CGFloat(((Array(text).count + charsPerLine - 1) / charsPerLine)) * lineHeight
    }

    static func run() {
        testShortTextIsUnchanged()
        testLongTextStartsWithEllipsisAndFits()
        testReturnedCutIsTheLongestFittingTail()
        testSingleCharacterTextIsUnchanged()
        testZeroLinesFallsBackToEllipsisPlusNewestChar()
    }

    private static func testShortTextIsUnchanged() {
        let text = "короткая строка"
        TestSupport.expectEqual(OverlayTextFitter.fitTail(text, maxLines: 2,
                                                          lineHeight: lineHeight,
                                                          measure: measure), text)
    }

    private static func testLongTextStartsWithEllipsisAndFits() {
        let text = String(repeating: "слово ", count: 60) // 360 chars ≈ 9 lines
        let fitted = OverlayTextFitter.fitTail(text, maxLines: 2,
                                               lineHeight: lineHeight,
                                               measure: measure)
        TestSupport.expect(fitted.hasPrefix("…"), "long text must be head-trimmed with an ellipsis")
        TestSupport.expect(fitted.count < text.count, "fitted text must be shorter than the source")
        TestSupport.expect(fitted.hasSuffix(String(text.suffix(1))),
                           "the newest character must survive the trim")
        TestSupport.expect(measure(fitted) <= lineHeight * 2 + 0.5,
                           "fitted text must fit within 2 lines")
    }

    private static func testReturnedCutIsTheLongestFittingTail() {
        let text = String(repeating: "абвгд ", count: 50) // 300 chars
        let fitted = OverlayTextFitter.fitTail(text, maxLines: 2,
                                               lineHeight: lineHeight,
                                               measure: measure)
        // Removing one more character from the cut must stop fitting (the cut
        // is the SMALLEST fitting mid — the longest visible tail).
        let tail = Array(fitted.dropFirst()) // without "…"
        let tailStart = text.count - tail.count - 1
        let oneLonger = "…" + String(Array(text)[tailStart...])
        TestSupport.expect(
            measure(oneLonger) > lineHeight * 2 + 0.5,
            "a longer tail than the returned one must not fit")
    }

    private static func testSingleCharacterTextIsUnchanged() {
        TestSupport.expectEqual(OverlayTextFitter.fitTail("я", maxLines: 2,
                                                          lineHeight: lineHeight,
                                                          measure: measure), "я")
    }

    private static func testZeroLinesFallsBackToEllipsisPlusNewestChar() {
        let fitted = OverlayTextFitter.fitTail("текст", maxLines: 2,
                                               lineHeight: 0,
                                               measure: { _ in 999 })
        TestSupport.expectEqual(fitted, "…т")
    }
}
