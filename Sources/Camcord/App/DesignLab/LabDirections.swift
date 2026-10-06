import SwiftUI

// The design directions' key tokens. Backdrops are each direction's window backgrounds, light
// then dark.
extension LabDirection {
    /// Graphite first: the app's window shape and spacing come from it.
    static let all: [LabDirection] = [graphite, frost, console, candy]

    static let graphite = LabDirection(
        id: "graphite", name: "Graphite", accent: Color(hex: 0x8FB0F0),
        clearGlass: false, glassTint: Color(hex: 0x54545C).opacity(0.40),
        surfaceRadius: 22, controlRadius: 8, spacing: 4,
        morph: .spring(duration: 0.32, bounce: 0.10), arrivalBlur: 8, arrivalScale: 0.94,
        backdrop: [Color(hex: 0x1C1C1E), Color(hex: 0x2A2A2E)],
        prefersDark: true)

    static let frost = LabDirection(
        id: "frost", name: "Frost", accent: Color(hex: 0x3563D6),
        clearGlass: false, glassTint: Color(hex: 0xEEF3FA).opacity(0.35),
        surfaceRadius: 22, controlRadius: 11, spacing: 8,
        morph: .spring(duration: 0.40, bounce: 0.06), arrivalBlur: 8, arrivalScale: 0.94,
        backdrop: [Color(hex: 0xF8F9FC), Color(hex: 0xDCE4F2)],
        prefersDark: false)

    static let console = LabDirection(
        id: "console", name: "Console", accent: Color(hex: 0xD2343A),
        clearGlass: false, glassTint: Color(hex: 0x191C20).opacity(0.86),
        surfaceRadius: 12, controlRadius: 6, spacing: 6,
        morph: .spring(duration: 0.26, bounce: 0), arrivalBlur: 0, arrivalScale: 0.98,
        backdrop: [Color(hex: 0x16181B), Color(hex: 0x1B1E22)],
        prefersDark: true)

    static let candy = LabDirection(
        id: "candy", name: "Candy", accent: Color(hex: 0x6A45FF),
        clearGlass: true, glassTint: Color(hex: 0xFFF4FB).opacity(0.30),
        surfaceRadius: 28, controlRadius: 999, spacing: 4,
        morph: .spring(duration: 0.40, bounce: 0.28), arrivalBlur: 10, arrivalScale: 0.90,
        backdrop: [Color(hex: 0xFFB38A), Color(hex: 0x7FE0E0), Color(hex: 0x9C8CFF)],
        prefersDark: false)
}

extension Color {
    /// An sRGB colour from 0xRRGGBB, as the prototypes write their tokens.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
