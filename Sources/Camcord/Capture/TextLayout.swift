import CoreGraphics

/// One recognized line of text with its bounding box in FULL-image pixel coordinates
/// (top-left origin, y increasing downward — so natural reading order is ascending y).
struct TextLine: Equatable, Sendable {
    let text: String
    let rect: CGRect
}

/// Pure text-layout logic for OCR: rebuilds STRUCTURED text from Vision's position-tagged line
/// observations — correct top-to-bottom reading order, blank lines on paragraph gaps, and
/// conservative indentation / column spacing derived from the horizontal positions (so code and
/// tables keep their shape instead of collapsing to a flat blob). Also plans the parallel strip
/// tiling for tall images and de-duplicates the strip overlaps. No Vision / AppKit types, so
/// it's fully unit-testable.
enum TextLayout {

    // MARK: - Tiling (parallel recognition of tall images)

    /// Full-width horizontal strips (overlapping) to recognize in parallel. Returns a single
    /// strip (the whole image) for anything that isn't clearly tall — most captures — so the
    /// common path stays one fast pass; a long scroll/page grab is split so the passes run
    /// concurrently AND Vision isn't forced to downscale a giant image (which loses small text).
    static func strips(imageWidth w: Int, imageHeight h: Int,
                       stripHeight: CGFloat = 1400, overlap: CGFloat = 160) -> [CGRect] {
        let width = CGFloat(w), height = CGFloat(h)
        guard height > stripHeight * 2, height > width else {
            return [CGRect(x: 0, y: 0, width: width, height: height)]
        }
        var rects: [CGRect] = []
        var top: CGFloat = 0
        while top < height {
            let sliceHeight = min(stripHeight, height - top)
            rects.append(CGRect(x: 0, y: top, width: width, height: sliceHeight))
            if top + sliceHeight >= height { break }
            top += stripHeight - overlap
        }
        return rects
    }

    /// Drops lines duplicated because they fell in two strips' overlap: identical text at a
    /// near-identical position in both axes.
    static func dedupOverlaps(_ lines: [TextLine]) -> [TextLine] {
        let sorted = lines.sorted { $0.rect.minY < $1.rect.minY }
        var kept: [TextLine] = []
        for line in sorted {
            let duplicate = kept.contains { existing in
                existing.text == line.text
                    && abs(existing.rect.midY - line.rect.midY) < max(existing.rect.height, line.rect.height, 1) * 0.5
                    && abs(existing.rect.midX - line.rect.midX) < max(existing.rect.width, line.rect.width, 1) * 0.5
                    && existing.rect.intersection(line.rect).width > min(existing.rect.width, line.rect.width) * 0.5
            }
            if !duplicate { kept.append(line) }
        }
        return kept
    }

    // MARK: - Structure assembly

    /// Assembles the recognized lines into structured text.
    static func assemble(_ lines: [TextLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let sorted = lines.sorted { $0.rect.minY < $1.rect.minY }

        // Group observations whose vertical spans overlap into one visual row (handles words
        // Vision returned as separate side-by-side observations — columns / tables).
        var rows: [[TextLine]] = []
        for line in sorted {
            if let last = rows.indices.last, isSameRow(rows[last], line) {
                rows[last].append(line)
            } else {
                rows.append([line])
            }
        }

        let charWidth = medianCharWidth(lines)
        var blocks: [[[TextLine]]] = []
        for row in rows {
            let ordered = row.sorted { $0.rect.minX < $1.rect.minX }
            let first = ordered[0]
            if let previous = blocks.last?.last, let previousFirst = previous.first {
                let bottom = previous.map { $0.rect.maxY }.max() ?? 0
                let paragraphGap = first.rect.minY - bottom > max(first.rect.height, 1) * 0.75
                let columnGap = first.rect.minX > previousFirst.rect.maxX + charWidth * 8
                    || previousFirst.rect.minX > first.rect.maxX + charWidth * 8
                if !paragraphGap && !columnGap {
                    blocks[blocks.count - 1].append(ordered)
                    continue
                }
            }
            blocks.append([ordered])
        }

        var out: [String] = []
        var prevBottom: CGFloat?
        for block in blocks {
            let blockMinX = block.compactMap { $0.first?.rect.minX }.min() ?? 0
            for ordered in block {
                let rowTop = ordered.map { $0.rect.minY }.min() ?? 0
                let rowBottom = ordered.map { $0.rect.maxY }.max() ?? 0
                let rowHeight = max(rowBottom - rowTop, 1)
                // A clearly larger-than-a-line vertical gap = a paragraph break (blank line).
                if let prevBottom, rowTop - prevBottom > rowHeight * 0.75 {
                    out.append("")
                }
                out.append(composeRow(ordered, charWidth: charWidth, blockMinX: blockMinX))
                prevBottom = rowBottom
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Two observations are on the same visual row when their vertical extents overlap by more
    /// than ~40% of the candidate's height.
    static func isSameRow(_ row: [TextLine], _ line: TextLine) -> Bool {
        let top = row.map { $0.rect.minY }.min() ?? line.rect.minY
        let bottom = row.map { $0.rect.maxY }.max() ?? line.rect.maxY
        let overlap = min(bottom, line.rect.maxY) - max(top, line.rect.minY)
        return overlap > line.rect.height * 0.4
    }

    /// Median glyph width across all lines (box width ÷ character count) — the yardstick for
    /// turning horizontal offsets into space counts.
    static func medianCharWidth(_ lines: [TextLine]) -> CGFloat {
        let widths = lines.compactMap { line -> CGFloat? in
            let count = line.text.count
            guard count > 0, line.rect.width > 0 else { return nil }
            return line.rect.width / CGFloat(count)
        }.sorted()
        guard !widths.isEmpty else { return 0 }
        return widths[widths.count / 2]
    }

    /// Renders one row: leading indentation (only when clearly indented, so left-aligned prose
    /// isn't given phantom spaces) + each observation, separated by a gap-proportional number
    /// of spaces (so tabular columns keep their separation).
    private static func composeRow(_ ordered: [TextLine], charWidth: CGFloat, blockMinX: CGFloat) -> String {
        guard let first = ordered.first else { return "" }
        var result = ""
        if charWidth > 0 {
            let indent = Int(((first.rect.minX - blockMinX) / charWidth).rounded())
            if indent >= 2 { result += String(repeating: " ", count: min(indent, 8)) }
        }
        result += first.text
        for i in 1..<ordered.count {
            let gap = ordered[i].rect.minX - ordered[i - 1].rect.maxX
            let spaces = charWidth > 0 ? max(1, Int((gap / charWidth).rounded())) : 1
            result += String(repeating: " ", count: min(spaces, 12))
            result += ordered[i].text
        }
        return result
    }
}
