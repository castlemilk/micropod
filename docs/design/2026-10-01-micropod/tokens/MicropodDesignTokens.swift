import SwiftUI

/// Design-kit reference only; this file is outside the Micropod app target.
/// Adopt semantic AppKit colors where native accessibility adaptation is needed.
enum MicropodDesignTokens {
    struct Palette {
        let canvas: Color
        let sidebar: Color
        let surface: Color
        let elevated: Color
        let primary: Color
        let secondary: Color
        let tertiary: Color
        let separator: Color
        let controlBorder: Color
        let accent: Color
        let accentText: Color
        let actionFill: Color
        let success: Color
        let warning: Color
        let danger: Color
        let selection: Color
        let focus: Color
    }

    static func palette(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }

    static let dark = Palette(
        canvas: rgb(0x151719), sidebar: rgb(0x1B1E22), surface: rgb(0x1F2328),
        elevated: rgb(0x292E35), primary: rgb(0xF3F5F7), secondary: rgb(0xB8C0CC),
        tertiary: rgb(0x98A3B3), separator: rgb(0x3D4652), controlBorder: rgb(0x7C8999),
        accent: rgb(0x0A84FF), accentText: rgb(0x73B6FF), actionFill: rgb(0x0067CF),
        success: rgb(0x68D6A0), warning: rgb(0xE6B65D), danger: rgb(0xFF8888),
        selection: rgb(0x163452), focus: rgb(0x73B6FF))

    static let light = Palette(
        canvas: rgb(0xF5F5F3), sidebar: rgb(0xECEDEA), surface: rgb(0xFFFFFF),
        elevated: rgb(0xFFFFFF), primary: rgb(0x1D242D), secondary: rgb(0x4E5A69),
        tertiary: rgb(0x606B79), separator: rgb(0xD7DBE0), controlBorder: rgb(0x858F9D),
        accent: rgb(0x0067CF), accentText: rgb(0x0067CF), actionFill: rgb(0x0067CF),
        success: rgb(0x197548), warning: rgb(0x8A5900), danger: rgb(0xBA3038),
        selection: rgb(0xE4F0FF), focus: rgb(0x0067CF))

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let contentInset: CGFloat = 20
    }

    enum Radius {
        static let control: CGFloat = 6
        static let panel: CGFloat = 10
        static let popover: CGFloat = 14
    }

    enum Layout {
        static let sidebar: CGFloat = 200
        static let inspector: CGFloat = 360
        static let tableRow: CGFloat = 40
        static let tableRowWithSubtitle: CGFloat = 48
        static let controlHeight: CGFloat = 28
        static let trayRow: CGFloat = 44
        static let trayWidth: CGFloat = 360
    }

    enum Typography {
        static let windowTitle = Font.system(size: 13, weight: .semibold)
        static let pageTitle = Font.system(size: 22, weight: .semibold)
        static let section = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let metadata = Font.system(size: 11)
        static let metric = Font.system(size: 20, weight: .medium).monospacedDigit()
        static let log = Font.system(size: 12, design: .monospaced)
    }

    enum Chart {
        struct Series {
            let cpu: Color
            let memory: Color
            let networkIn: Color
            let networkOut: Color
        }

        static func colors(for scheme: ColorScheme) -> Series {
            if scheme == .dark {
                return Series(
                    cpu: rgb(0x73B6FF), memory: rgb(0x65D2C3),
                    networkIn: rgb(0xB7A6F7), networkOut: rgb(0xE6B65D))
            }
            return Series(
                cpu: rgb(0x0067CF), memory: rgb(0x127E71),
                networkIn: rgb(0x6D51B7), networkOut: rgb(0x8A5900))
        }
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(
            .sRGB, red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255, opacity: 1)
    }
}
