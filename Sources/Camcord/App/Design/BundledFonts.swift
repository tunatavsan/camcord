import AppKit
import CoreText

/// Registers the bundled face for this process only. Immutable CoreText descriptors are
/// thread-safe; keeping the file descriptor also avoids resolving a similarly named face.
struct BundledFonts: @unchecked Sendable {
    static let fileName = "DMSans[opsz,wght].ttf"
    static let weightAxis = NSNumber(value: 0x77676874) // wght
    static let opticalSizeAxis = NSNumber(value: 0x6F70737A) // opsz
    static let application = BundledFonts(fontURL: Bundle.main.url(
        forResource: "DMSans[opsz,wght]", withExtension: "ttf", subdirectory: "Fonts"))

    private let descriptor: CTFontDescriptor?
    let familyName: String?

    init(fontURL: URL?) {
        guard let fontURL,
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            self.descriptor = nil
            familyName = nil
            return
        }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
        let registrationError = error?.takeRetainedValue()
        guard registered || registrationError.map({ CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue }) == true else {
            self.descriptor = nil
            familyName = nil
            return
        }
        self.descriptor = descriptor
        familyName = CTFontCopyFamilyName(CTFontCreateWithFontDescriptor(descriptor, 14, nil)) as String
    }

    func text(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let descriptor else { return NSFont.systemFont(ofSize: size, weight: weight) }
        let variations: [NSNumber: NSNumber] = [
            Self.weightAxis: NSNumber(value: Self.axisWeight(weight)),
            Self.opticalSizeAxis: NSNumber(value: Double(min(40, max(9, size)))),
        ]
        let attributes = [kCTFontVariationAttribute as String: variations] as CFDictionary
        let sizedDescriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes)
        return CTFontCreateWithFontDescriptor(sizedDescriptor, size, nil) as NSFont
    }

    private static func axisWeight(_ weight: NSFont.Weight) -> Double {
        switch weight {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }
}
