import Combine
import Foundation

struct SubtitleCue: Equatable, Sendable, Identifiable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    init(start: TimeInterval, end: TimeInterval, text: String) {
        id = UUID()
        self.start = start
        self.end = end
        self.text = text
    }
}

enum SubtitleCueParser {
    static func parse(data: Data, fileName: String) throws -> [SubtitleCue] {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "srt": return parseSRT(text)
        case "ass", "ssa": return parseASS(text)
        default: throw SubtitleCueParserError.unsupportedFormat
        }
    }

    static func activeCues(in cues: [SubtitleCue], at time: TimeInterval) -> [SubtitleCue] {
        cues.filter { $0.start <= time && time < $0.end }
    }

    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2, let start = srtTime(timing[0]), let end = srtTime(timing[1]), end > start else { return nil }
            let subtitle = lines.dropFirst(timingIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return subtitle.isEmpty ? nil : SubtitleCue(start: start, end: end, text: subtitle)
        }
    }

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var inEvents = false
        return text.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.caseInsensitiveCompare("[Events]") == .orderedSame { inEvents = true; return nil }
            guard inEvents, trimmed.lowercased().hasPrefix("dialogue:") else { return nil }
            let fields = trimmed.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 10, let start = assTime(fields[1]), let end = assTime(fields[2]), end > start else { return nil }
            let plain = fields[9]
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? nil : SubtitleCue(start: start, end: end, text: plain)
        }
    }

    private static func srtTime(_ value: String) -> TimeInterval? {
        let pieces = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard pieces.count == 3, let hours = Double(pieces[0]), let minutes = Double(pieces[1]), let seconds = Double(pieces[2]) else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func assTime(_ value: String) -> TimeInterval? {
        let pieces = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard pieces.count == 3, let hours = Double(pieces[0]), let minutes = Double(pieces[1]), let seconds = Double(pieces[2]) else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }
}

enum SubtitleCueParserError: Error { case unsupportedFormat }

@MainActor
final class SubtitleOverlayModel: ObservableObject {
    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var activeText: String?

    func install(_ cues: [SubtitleCue]) { self.cues = cues }
    func clear() { cues = []; activeText = nil }
    func update(time: TimeInterval) {
        let text = SubtitleCueParser.activeCues(in: cues, at: time).map(\.text).joined(separator: "\n")
        activeText = text.isEmpty ? nil : text
    }
}
