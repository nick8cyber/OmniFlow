import Foundation

/// Port of the Windows `OverlayTextFit.FitTail` (ADR-0005 parity): fits a
/// transcript into the overlay's text block by trimming from its START so the
/// newest words stay visible — pure tail-ellipsis would hide exactly the part
/// being dictated right now, and SwiftUI's `.truncationMode(.head)` does not
/// drop whole lines on frequent updates (it rendered stale text — the bug this
/// replaces). The predicate "the suffix starting at mid fits" is monotone, so
/// the SMALLEST fitting mid is the longest visible tail; searching for the
/// largest fitting mid instead collapses the transcript to an ellipsis plus one
/// character.
enum OverlayTextFitter {
    /// `measure` returns the rendered height of a single-line variant of the
    /// given text at the overlay's real font and width; `lineHeight` is the
    /// rendered line height. A text fits when its measured height stays within
    /// `lineHeight * maxLines`.
    static func fitTail(_ text: String,
                        maxLines: Int,
                        lineHeight: CGFloat,
                        measure: (String) -> CGFloat) -> String {
        guard !text.isEmpty, maxLines > 0 else { return text }
        let heightLimit = lineHeight * CGFloat(maxLines) + 0.5
        if measure(text) <= heightLimit { return text }
        let chars = Array(text)
        let count = chars.count
        guard count > 1 else { return text }
        func fits(_ mid: Int) -> Bool {
            measure("…" + String(chars[mid...])) <= heightLimit
        }
        var lo = 1, hi = count - 1
        var best = count - 1 // fallback: ellipsis + the newest character
        while lo <= hi {
            let mid = (lo + hi) / 2
            if fits(mid) {
                best = mid
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        return "…" + String(chars[best...])
    }
}
