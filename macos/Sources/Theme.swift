import AppKit
import SwiftUI

enum Theme {
    static let accent = NSColor(srgbRed: 0.49, green: 0.78, blue: 1.0, alpha: 1)        // #7DC8FF
    static let accentDeep = NSColor(srgbRed: 0.12, green: 0.50, blue: 0.78, alpha: 1)   // #1F7FC8
    static let accentUI = Color(red: 0.49, green: 0.78, blue: 1.0)
    static let onAccent = Color(red: 0.02, green: 0.07, blue: 0.11)

    static func isDark(_ appearance: NSAppearance? = NSApp?.effectiveAppearance) -> Bool {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func background(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.04, green: 0.04, blue: 0.05) : .white
    }
    static func surface(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.09, green: 0.09, blue: 0.10) : Color(red: 0.95, green: 0.97, blue: 0.99)
    }
    static func line(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }
    static func accentText(_ s: ColorScheme) -> Color {
        s == .dark ? accentUI : Color(red: 0.12, green: 0.50, blue: 0.78)
    }
}
