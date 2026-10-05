import CoreGraphics

/// Finds the columns of a scroll capture that actually scroll. A web app's sidebar or rail is
/// fixed beside the page: the capture area holds both, and stitched whole rows would repeat the
/// sidebar in every strip. Two frames a known shift apart tell them apart column by column: a
/// fixed column shows the same thing in both, a scrolling one shows it `shift` rows higher.
///
/// Pure pixel logic, unit-testable without a display.
enum ScrollColumns {
    /// A column is fixed (or scrolling) when one reading beats the other by this much.
    private static let margin = 3.0
    /// Rows the two frames share exactly at the top or bottom (a sticky header) say nothing.
    private static let bandLimit = 2.0

    /// The span of pixel columns that scrolled between `earlier` and `later`, where `later` shows
    /// `earlier` moved up by `shift` rows. Nil when no side is fixed, or when what scrolls would
    /// be too narrow to trust.
    static func scrolling(earlier: CGImage, later: CGImage, shift: Int) -> Range<Int>? {
        let width = earlier.width
        let height = earlier.height
        guard later.width == width, later.height == height, width >= 64,
              shift >= 8, shift < height * 5 / 6 else { return nil }
        // Half the width is enough to place an edge within a point on a Retina capture.
        let columns = width / 2
        guard let a = gray(earlier, columns: columns), let b = gray(later, columns: columns) else { return nil }

        func rowDiff(_ ra: Int, _ rb: Int) -> Double {
            var sum = 0
            for x in 0..<columns { sum += abs(Int(a[ra * columns + x]) - Int(b[rb * columns + x])) }
            return Double(sum) / Double(columns)
        }
        var top = 0
        while top < height / 3, rowDiff(top, top) <= bandLimit { top += 1 }
        var bottom = 0
        while bottom < height / 3, rowDiff(height - 1 - bottom, height - 1 - bottom) <= bandLimit { bottom += 1 }
        let rows = stride(from: top, to: height - bottom - shift, by: 2)
        guard rows.underestimatedCount > 16 else { return nil }

        var stayed = [Int](repeating: 0, count: columns)
        var moved = [Int](repeating: 0, count: columns)
        var count = 0
        for r in rows {
            let row = r * columns
            let source = (r + shift) * columns
            for x in 0..<columns {
                let value = Int(b[row + x])
                stayed[x] += abs(value - Int(a[row + x]))
                moved[x] += abs(value - Int(a[source + x]))
            }
            count += 1
        }
        enum Kind { case fixed, scrolling, unknown }
        let kinds: [Kind] = (0..<columns).map { x in
            let s = Double(stayed[x]) / Double(count)
            let m = Double(moved[x]) / Double(count)
            if s + margin < m { return .fixed }
            if m + margin < s { return .scrolling }
            return .unknown   // plain background reads the same either way
        }
        guard let firstScrolling = kinds.firstIndex(of: .scrolling),
              let lastScrolling = kinds.lastIndex(of: .scrolling) else { return nil }

        // A side is fixed when real evidence, not one stray column, stayed put before the page.
        let evidence = max(6, columns / 100)
        // Up to this much plain margin beside the page is kept.
        let keep = 16
        var left = 0
        let leftFixed = kinds[..<firstScrolling].indices.filter { kinds[$0] == .fixed }
        if leftFixed.count >= evidence, let last = leftFixed.last {
            left = max(last + 1, firstScrolling - keep)
        }
        var right = columns
        let rightFixed = kinds[(lastScrolling + 1)...].indices.filter { kinds[$0] == .fixed }
        if rightFixed.count >= evidence, let first = rightFixed.first {
            right = min(first, lastScrolling + 1 + keep)
        }
        guard left > 0 || right < columns, right - left >= columns * 2 / 5 else { return nil }
        // Back to the image's own pixel columns.
        return (left * width / columns)..<(right * width / columns)
    }

    /// Grayscale pixels, `columns` wide and full height, top row first.
    private static func gray(_ image: CGImage, columns: Int) -> [UInt8]? {
        let height = image.height
        guard let context = CGContext(data: nil, width: columns, height: height, bitsPerComponent: 8,
                                      bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        // A bitmap context is bottom-left and draws the image's top row into buffer row 0.
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: height))
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: columns * height),
                                         count: columns * height))
    }
}
