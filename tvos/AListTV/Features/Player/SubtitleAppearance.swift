import Foundation
import SwiftUI

struct SubtitleAppearance: Codable, Equatable, Sendable {
    enum FontChoice: String, Codable, CaseIterable, Sendable, Identifiable {
        case systemSans
        case roundedSans
        case serif
        case monospace

        var id: String { rawValue }

        var title: String {
            switch self {
            case .systemSans: "System Sans"
            case .roundedSans: "Rounded Sans"
            case .serif: "Serif"
            case .monospace: "Monospace"
            }
        }

        var vlcFontName: String {
            switch self {
            case .systemSans: "Helvetica Neue"
            case .roundedSans: "Avenir Next"
            case .serif: "Georgia"
            case .monospace: "Menlo"
            }
        }

        var previewFont: Font {
            switch self {
            case .systemSans: .system(.title3, design: .default)
            case .roundedSans: .system(.title3, design: .rounded)
            case .serif: .system(.title3, design: .serif)
            case .monospace: .system(.title3, design: .monospaced)
            }
        }
    }

    enum ColorChoice: String, Codable, CaseIterable, Sendable, Identifiable {
        case white
        case yellow
        case cyan
        case green

        var id: String { rawValue }

        var title: String { rawValue.capitalized }

        var vlcHexColor: String {
            switch self {
            case .white: "#FFFFFF"
            case .yellow: "#FFFF00"
            case .cyan: "#00FFFF"
            case .green: "#00FF66"
            }
        }

        var previewColor: Color {
            switch self {
            case .white: .white
            case .yellow: .yellow
            case .cyan: .cyan
            case .green: .green
            }
        }
    }

    enum OpacityChoice: Int, Codable, CaseIterable, Sendable, Identifiable {
        case full = 100
        case high = 75
        case medium = 50
        case low = 25

        var id: Int { rawValue }
        var title: String { "\(rawValue)%" }
        var fraction: Double { Double(rawValue) / 100 }
        var vlcOpacity: Int { Int((fraction * 255).rounded()) }
    }

    var font: FontChoice
    var color: ColorChoice
    var opacity: OpacityChoice

    static let `default` = SubtitleAppearance(font: .systemSans, color: .white, opacity: .full)

    var vlcMediaOptions: [String] {
        [
            ":freetype-font=\(font.vlcFontName)",
            ":freetype-color=\(color.vlcHexColor)",
            ":freetype-opacity=\(opacity.vlcOpacity)"
        ]
    }
}

struct SubtitleAppearanceStore {
    private struct Payload: Codable {
        let version: Int
        let appearance: SubtitleAppearance
    }

    private static let key = "com.alist.tv.subtitle-appearance-v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SubtitleAppearance {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1 else {
            return .default
        }
        return payload.appearance
    }

    func save(_ appearance: SubtitleAppearance) {
        let payload = Payload(version: 1, appearance: appearance)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
