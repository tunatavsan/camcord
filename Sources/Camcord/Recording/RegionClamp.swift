import CoreGraphics

/// Pure geometry for region *recording*. Unlike screenshots (`captureImage(in:)` is
/// display-agnostic), an `SCStream` records from exactly one display: its filter is
/// display-bound and `SCStreamConfiguration.sourceRect` is display-relative. A dragged
/// region that spans displays therefore has to be clamped to a single display -- the
/// one containing the region's center.
///
/// Works on plain rects/scales (no ScreenCaptureKit types) so it stays unit-testable.
enum RegionClamp {

    /// One display's frame in CG screen space plus its backing scale.
    struct DisplayFrame: Equatable {
        let frame: CGRect
        let scale: CGFloat

        init(frame: CGRect, scale: CGFloat) {
            self.frame = frame
            self.scale = scale
        }
    }

    struct Result: Equatable {
        /// Index into the `displays` array the region was clamped to.
        let displayIndex: Int
        /// The region intersected with that display's bounds, still in CG screen space.
        let clampedRegion: CGRect
        /// `clampedRegion` translated to the display's own coordinate space (origin at
        /// the display's top-left) -- what `SCStreamConfiguration.sourceRect` wants.
        let sourceRect: CGRect
        /// Output size in pixels, floored to even integers (encoder requirement).
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func clamp(region: CGRect, displays: [DisplayFrame]) -> Result? {
        guard !displays.isEmpty else { return nil }

        let center = CGPoint(x: region.midX, y: region.midY)
        let index =
            displays.firstIndex { $0.frame.contains(center) }
            ?? displays.indices.max { areaOfIntersection(region, displays[$0].frame) < areaOfIntersection(region, displays[$1].frame) }
        guard let index else { return nil }

        let display = displays[index]
        let clamped = region.intersection(display.frame)
        guard !clamped.isEmpty else { return nil }

        let sourceRect = clamped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        return Result(
            displayIndex: index,
            clampedRegion: clamped,
            sourceRect: sourceRect,
            pixelWidth: evenFloor(clamped.width * display.scale),
            pixelHeight: evenFloor(clamped.height * display.scale)
        )
    }

    /// Floors to an even integer -- H.264/HEVC encoders reject odd dimensions.
    static func evenFloor(_ value: CGFloat) -> Int {
        Int(value.rounded(.down)) & ~1
    }

    private static func areaOfIntersection(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isEmpty ? 0 : intersection.width * intersection.height
    }
}
