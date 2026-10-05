import CoreGraphics

/// A window's bottom edge under a scroll capture: its rounded corners would be cut into every
/// stitched strip, so they are taken from the last frame only and close the image once.
enum ScrollCorners {
    /// The bottom `count` rows of `image`, copied into their own bitmap.
    static func copyBottomRows(of image: CGImage, count: Int) -> CGImage? {
        guard count > 0, count <= image.height,
              let context = context(width: image.width, height: count, like: image) else { return nil }
        // Bottom-left origin: the image's last rows land in the context's only rows.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// `image` with `tail` under it, the tail's outer corners rounded by its own height and
    /// clear outside the curve, the way a window's screenshot is.
    static func appending(_ tail: CGImage, to image: CGImage, roundLeft: Bool, roundRight: Bool) -> CGImage? {
        guard tail.width == image.width,
              let context = context(width: image.width, height: image.height + tail.height, like: image) else { return nil }
        let width = CGFloat(image.width), rows = CGFloat(tail.height)
        context.draw(image, in: CGRect(x: 0, y: rows, width: width, height: CGFloat(image.height)))
        let edge = CGMutablePath()
        edge.move(to: CGPoint(x: 0, y: rows))
        if roundLeft {
            edge.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: rows, y: 0), radius: rows)
        } else {
            edge.addLine(to: .zero)
        }
        if roundRight {
            edge.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width, y: rows), radius: rows)
        } else {
            edge.addLine(to: CGPoint(x: width, y: 0))
        }
        edge.addLine(to: CGPoint(x: width, y: rows))
        edge.closeSubpath()
        context.addPath(edge)
        context.clip()
        context.draw(tail, in: CGRect(x: 0, y: 0, width: width, height: rows))
        return context.makeImage()
    }

    private static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
