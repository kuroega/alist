import Foundation

/// What a video's filename and folders say about the title inside.
struct ParsedMedia: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case movie
        case episode
    }

    var kind: Kind
    /// Movie title, or the show title for an episode.
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?
    /// Episode name carried by the filename, e.g. "Pilot" in `S01E01 Pilot.mkv`.
    var episodeTitle: String?
    /// Display badges such as "4K", "Dolby Vision", "Atmos".
    var qualities: [String]

    /// Grouping key: the same title written with dots, spaces, or different
    /// case lands on the same show or movie.
    var titleKey: String { MediaNameParser.key(for: title) }
}

/// Turns release-style and CJK filenames into searchable titles.
///
/// Handles `Show.S01E02`, `1x02`, `第2季 第05集`, anime `Title - 05`, plain
/// numbered files inside `Season 1` folders, and `Movie (2014)` / `Movie.2014.1080p`
/// names, stripping site tags, release groups and encoding junk.
enum MediaNameParser {
    /// Stored with every indexed file. Bump it whenever `parse` changes so the
    /// Gallery store parses its saved files again instead of keeping old titles.
    static let version = 1

    static func parse(path: String) -> ParsedMedia {
        let components = path.split(separator: "/").map(String.init)
        guard let fileName = components.last else {
            return ParsedMedia(kind: .movie, title: path, qualities: [])
        }
        let folders = Array(components.dropLast())
        let stem = stripExtension(fileName)
        let qualities = detectQualities(in: fileName)

        let parentSeason = folders.last.flatMap(seasonNumber(inFolder:))
        if let episode = parseEpisode(stem: stem, folders: folders, folderSeason: parentSeason) {
            return ParsedMedia(
                kind: .episode,
                title: episode.show,
                year: episode.year,
                season: episode.season,
                episode: episode.episode,
                episodeTitle: episode.episodeTitle,
                qualities: qualities
            )
        }

        var (title, year) = cleanTitleAndYear(stem)
        // Generic or year-less file names defer to a curated `Title (Year)` folder.
        if let parent = folders.last, !isGenericContainer(parent) {
            let folder = cleanTitleAndYear(parent)
            if !folder.title.isEmpty, (year == nil && folder.year != nil) || isGenericFileTitle(title) {
                title = folder.title
                year = folder.year ?? year
            }
        }
        if title.isEmpty { title = stem }
        return ParsedMedia(kind: .movie, title: title, year: year, qualities: qualities)
    }

    /// Lowercased letters and digits only, so punctuation and spacing never
    /// split one title into two.
    static func key(for title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Search fallbacks for mixed-script names such as `星际穿越 Interstellar`:
    /// the full title first, then each script on its own.
    static func searchQueries(for title: String) -> [String] {
        var queries = [title]
        // `The Office US` is listed as `The Office`; keep the country as a fallback only.
        let withoutCountry = title.replacingOccurrences(of: #"(?i)\s*\(?\b(us|uk)\)?$"#, with: "", options: .regularExpression)
        if withoutCountry != title, withoutCountry.count >= 2 { queries.append(withoutCountry) }
        let scalars = title.unicodeScalars
        let hasCJK = scalars.contains(where: isCJK)
        let hasLatin = scalars.contains { $0.isASCII && CharacterSet.letters.contains($0) }
        if hasCJK && hasLatin {
            let cjk = collapse(String(String.UnicodeScalarView(scalars.map { isCJK($0) || CharacterSet.decimalDigits.contains($0) ? $0 : " " })))
            let latin = collapse(String(String.UnicodeScalarView(scalars.map { isCJK($0) ? " " : $0 })))
            for candidate in [cjk, latin] where candidate.count >= 2 && !queries.contains(candidate) {
                queries.append(candidate)
            }
        }
        return queries
    }

    // MARK: Episodes

    private struct EpisodeMatch {
        var show: String
        var year: Int?
        var season: Int
        var episode: Int
        var episodeTitle: String?
    }

    private static func parseEpisode(stem: String, folders: [String], folderSeason: Int?) -> EpisodeMatch? {
        let bracketEpisode = numericBracketContent(in: stem)
        let text = spaced(removingBrackets(stem))

        var season: Int?
        var episode: Int?
        var prefixEnd: String.Index?
        var suffixStart: String.Index?

        func take(_ match: NSTextCheckingResult, in string: String) {
            guard let range = Range(match.range, in: string) else { return }
            prefixEnd = range.lowerBound
            suffixStart = range.upperBound
        }

        if let match = firstMatch(seasonEpisodePattern, in: text) {
            season = intGroup(match, 1, in: text)
            episode = intGroup(match, 2, in: text)
            take(match, in: text)
        } else if let match = firstMatch(crossPattern, in: text) {
            season = intGroup(match, 1, in: text)
            episode = intGroup(match, 2, in: text)
            take(match, in: text)
        } else if let match = firstMatch(chineseEpisodePattern, in: text) {
            episode = chineseOrArabic(group(match, 1, in: text))
            take(match, in: text)
            if let seasonMatch = firstMatch(chineseSeasonPattern, in: text),
               let range = Range(seasonMatch.range, in: text) {
                season = chineseOrArabic(group(seasonMatch, 1, in: text))
                if let end = prefixEnd, range.lowerBound < end { prefixEnd = range.lowerBound }
            }
        } else if let match = firstMatch(episodeOnlyPattern, in: text) {
            episode = intGroup(match, 1, in: text)
            take(match, in: text)
        } else if let match = firstMatch(animePattern, in: text) {
            episode = intGroup(match, 1, in: text)
            take(match, in: text)
        } else if folderSeason != nil, let match = firstMatch(leadingNumberPattern, in: text) {
            episode = intGroup(match, 1, in: text)
            take(match, in: text)
        } else if folderSeason != nil, let number = bracketEpisode {
            episode = number
        }

        guard let episodeNumber = episode else { return nil }

        // A season named in the prefix (`Show S2 - 05`, `Show 第二季 05`) beats the folder.
        let rawPrefix = prefixEnd.map { String(text[..<$0]) } ?? ""
        var prefixSeason: Int?
        var prefix = rawPrefix
        if let match = firstMatch(trailingSeasonPattern, in: rawPrefix), let range = Range(match.range, in: rawPrefix) {
            prefixSeason = (1 ... 3).lazy.compactMap { chineseOrArabic(group(match, $0, in: rawPrefix)) }.first
            prefix = String(rawPrefix[..<range.lowerBound])
        }
        let resolvedSeason = season ?? prefixSeason ?? folderSeason ?? 1

        var (show, year) = cleanTitleAndYear(prefix)
        let showFolder = showFolderName(in: folders)
        if let showFolder {
            let folder = cleanTitleAndYear(showFolder)
            // `Show/Season 1/file` is a curated layout: trust the folder name.
            if folderSeason != nil || show.isEmpty {
                if !folder.title.isEmpty { show = folder.title }
                year = folder.year ?? year
            } else if key(for: folder.title) == key(for: show) {
                year = folder.year ?? year
            }
        }
        // `Shows/S01E02 Name.mkv`: an explicit episode marker outranks a generic folder name.
        if show.isEmpty, let parent = folders.last {
            show = cleanTitleAndYear(parent).title
        }
        guard !show.isEmpty else { return nil }

        var episodeTitle: String?
        if let start = suffixStart {
            let suffix = cleanEpisodeTitle(String(text[start...]))
            if !suffix.isEmpty { episodeTitle = suffix }
        }

        return EpisodeMatch(show: show, year: year, season: resolvedSeason, episode: episodeNumber, episodeTitle: episodeTitle)
    }

    /// Nearest folder above any season folder that is not a generic library container.
    private static func showFolderName(in folders: [String]) -> String? {
        for folder in folders.reversed() {
            if firstMatch(specialsPattern, in: spaced(folder)) != nil { continue }
            if seasonNumber(inFolder: folder) != nil, cleanTitleAndYear(stripSeason(folder)).title.isEmpty { continue }
            if isGenericContainer(folder) { return nil }
            let stripped = stripSeason(folder)
            return stripped.isEmpty ? nil : stripped
        }
        return nil
    }

    static func seasonNumber(inFolder name: String) -> Int? {
        let text = spaced(name)
        if firstMatch(specialsPattern, in: text) != nil { return 0 }
        if let match = firstMatch(seasonFolderPattern, in: text) {
            return chineseOrArabic(group(match, 1, in: text)) ?? chineseOrArabic(group(match, 2, in: text)) ?? chineseOrArabic(group(match, 3, in: text))
        }
        return nil
    }

    /// `Breaking Bad Season 2` → `Breaking Bad`, so show folders that also name a season still group.
    private static func stripSeason(_ folder: String) -> String {
        let text = spaced(folder)
        guard let match = firstMatch(seasonFolderPattern, in: text), let range = Range(match.range, in: text) else { return folder }
        return collapse(String(text[..<range.lowerBound]) + " " + String(text[range.upperBound...]))
    }

    private static func cleanEpisodeTitle(_ raw: String) -> String {
        var tokens: [String] = []
        for token in raw.split(separator: " ").map(String.init) {
            if isJunk(token) || yearValue(token) != nil { break }
            tokens.append(token)
        }
        return trimSeparators(tokens.joined(separator: " "))
    }

    // MARK: Titles

    /// Title and release year from a name, cutting at the year or the first
    /// encoding/source token.
    static func cleanTitleAndYear(_ raw: String) -> (title: String, year: Int?) {
        var text = removeSiteTags(normalizeBrackets(raw))
        let withoutBrackets = removingBrackets(text)
        text = trimSeparators(withoutBrackets).isEmpty ? bracketInner(text) : withoutBrackets
        text = spaced(text)

        var year: Int?
        var cut = text.endIndex
        let matches = yearPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // A leading number is the title (`1917`, `2012`); the last plausible year is the release.
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: text), range.lowerBound > text.startIndex,
                  let value = Int(text[range]), isPlausibleYear(value) else { continue }
            year = value
            cut = range.lowerBound
            break
        }

        // Release names put encoding tags after the year; words such as
        // "Complete" or "Web" before it belong to the title.
        var tokens: [String] = []
        for token in text[..<cut].split(separator: " ").map(String.init) {
            if year == nil ? isJunk(token) : isTechnicalJunk(token) { break }
            tokens.append(token)
        }
        var title = trimSeparators(tokens.joined(separator: " "))
        title = title.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        title = trimSeparators(stripPartSuffix(title))
        return (title, year)
    }

    private static func stripPartSuffix(_ title: String) -> String {
        title.replacingOccurrences(of: #"(?i)\s+(cd|disc|disk|part|pt)\s?\d{1,2}$"#, with: "", options: .regularExpression)
    }

    private static func isGenericFileTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        if lowered.isEmpty || genericFileTitles.contains(lowered) { return true }
        return lowered.allSatisfy(\.isNumber) && lowered.count <= 2
    }

    static func isGenericContainer(_ folder: String) -> Bool {
        genericContainers.contains(key(for: folder))
    }

    private static func isPlausibleYear(_ value: Int) -> Bool {
        let current = Calendar(identifier: .gregorian).component(.year, from: Date())
        return value >= 1900 && value <= current + 1
    }

    private static func yearValue(_ token: String) -> Int? {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
        guard trimmed.count == 4, let value = Int(trimmed), isPlausibleYear(value) else { return nil }
        return value
    }

    static func isJunk(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        return isTechnicalJunk(token) || releaseWordPattern.firstMatch(in: token, range: range) != nil
    }

    /// Resolution, source, codec and CJK subtitle tags: never part of a title.
    private static func isTechnicalJunk(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        if technicalJunkPattern.firstMatch(in: token, range: range) != nil { return true }
        return cjkJunkPattern.firstMatch(in: token, range: range) != nil
    }

    // MARK: Qualities

    static func detectQualities(in name: String) -> [String] {
        let text = " " + spaced(name.lowercased().replacingOccurrences(of: "-", with: " ")) + " "
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        var badges: [String] = []
        if has(#"[ \[(](2160p|4k|uhd)[ \])]"#) {
            badges.append("4K")
        } else if has(#"[ \[(]1080[pi][ \])]|1080p"#) {
            badges.append("1080p")
        } else if has(#"720p"#) {
            badges.append("720p")
        }
        if has(#" (dolby ?vision|dovi|dv) "#) {
            badges.append("Dolby Vision")
        } else if has(#" hdr(10\+?)? "#) {
            badges.append("HDR")
        }
        if has(#" atmos "#) {
            badges.append("Atmos")
        } else if has(#" (truehd|dts ?hd|dts ?x|dts) "#) {
            badges.append("DTS")
        }
        if has(#" remux "#) { badges.append("Remux") }
        return badges
    }

    // MARK: Text helpers

    private static func stripExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return name }
        let ext = name[name.index(after: dot)...]
        guard ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return name }
        return String(name[..<dot])
    }

    private static func normalizeBrackets(_ text: String) -> String {
        var result = text
        for (from, to) in [("【", "["), ("】", "]"), ("（", "("), ("）", ")"), ("《", " "), ("》", " "), ("「", " "), ("」", " ")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    private static func removeSiteTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(www\.[^\s\]\[]+|[a-z0-9-]+\.(com|net|org|cn|cc)\b)"#, with: " ", options: .regularExpression)
    }

    static func removingBrackets(_ text: String) -> String {
        normalizeBrackets(text).replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
    }

    private static func bracketInner(_ text: String) -> String {
        text.replacingOccurrences(of: #"[\[\]]"#, with: " ", options: .regularExpression)
    }

    private static func numericBracketContent(in text: String) -> Int? {
        guard let match = firstMatch(bracketNumberPattern, in: normalizeBrackets(text)) else { return nil }
        return intGroup(match, 1, in: normalizeBrackets(text))
    }

    /// Dots and underscores separate words in release names.
    static func spaced(_ text: String) -> String {
        collapse(text.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression))
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func trimSeparators(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_:,.·|+&(").union(.whitespaces))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xAC00 ... 0xD7AF, 0xF900 ... 0xFAFF: true
        default: false
        }
    }

    static func chineseOrArabic(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        if let value = Int(raw) { return value }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0
        var current = 0
        for character in raw {
            if let digit = digits[character] {
                current = digit
            } else if character == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
            } else if character == "百" {
                total += (current == 0 ? 1 : current) * 100
                current = 0
            } else {
                return nil
            }
        }
        return total + current
    }

    // MARK: Regex

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Int? {
        group(match, index, in: text).flatMap { Int($0) }
    }

    private static let seasonEpisodePattern = regex(#"(?<![a-z])s(\d{1,2})\s?-?\s?e(\d{1,4})(?:\s?-\s?e?\d{1,4}(?!\d)|e\d{1,4})?(?!\d)"#)
    private static let crossPattern = regex(#"(?<![\d])(\d{1,2})x(\d{2,3})(?!\d)"#)
    private static let chineseEpisodePattern = regex(#"第\s*([0-9零一二两三四五六七八九十百]+)\s*[集话話回]"#)
    private static let chineseSeasonPattern = regex(#"第\s*([0-9零一二两三四五六七八九十]+)\s*[季部]"#)
    private static let episodeOnlyPattern = regex(#"(?<![a-z])(?:ep|e)\s?(\d{1,3})(?![\dp])"#)
    private static let animePattern = regex(#"\s-\s(\d{1,3})(?:v\d)?(?=\s|$)"#)
    private static let leadingNumberPattern = regex(#"^(\d{1,3})(?![\dp])"#)
    private static let bracketNumberPattern = regex(#"\[(\d{1,3})(?:v\d)?\]"#)
    private static let trailingSeasonPattern = regex(#"(?:(?<![a-z])s(\d{1,2})|season\s?(\d{1,2})|第\s*([0-9零一二两三四五六七八九十]+)\s*[季部])\s*-?\s*$"#)
    private static let seasonFolderPattern = regex(#"(?:^|\s)(?:season\s?(\d{1,2})|s(\d{1,2})(?![\de])|第\s*([0-9零一二两三四五六七八九十]+)\s*[季部])(?:\s|$)"#)
    private static let specialsPattern = regex(#"^(specials?|sp|特别篇|特典)$"#)
    private static let yearPattern = regex(#"(?<![0-9])\(?((?:19|20)\d{2})\)?(?![0-9])"#)
    private static let technicalJunkPattern = regex(
        #"^([248]k|uhd|hd|fhd|blu-?ray|bdrip|brrip|bdremux|remux|web-?dl|webrip|hdtv|hdrip|dvdrip|dvdscr|hdr(10\+?)?|dovi|x26[45]|h-?26[45]|hevc|avc|av1|aac\d?|ac3|e?ac-?3|dts(-?hd)?|ddp?\d?|dd\+|atmos|truehd|flac|10bit|8bit|hi10p)$|\d{3,4}[pi]$|\d{3,4}p"#
    )
    private static let releaseWordPattern = regex(
        #"^(sd|bd|web|dv|sdr|dvd|proper|repack|extended|unrated|uncut|imax|internal|limited|multi|dual|subbed|dubbed|chs|cht|eng|nf|amzn|dsnp|hmax|atvp|complete|criterion)$"#
    )
    private static let cjkJunkPattern = regex(#"(国语|國語|粤语|粵語|中字|中英|双语|雙語|双字|字幕|高清|蓝光|藍光|超清|无水印|特效|简繁|繁中|简中|完整版|未删减|未刪減|内封|内嵌|外挂)"#)
    private static let genericFileTitles: Set<String> = ["movie", "film", "video", "main", "feature", "index", "playlist", "电影", "正片"]
    private static let genericContainers: Set<String> = [
        "", "movies", "movie", "films", "film", "tv", "tvshows", "tvshow", "shows", "series", "videos", "video", "media",
        "downloads", "download", "anime", "animation", "documentaries", "documentary", "kids", "library", "public", "share", "shared",
        "电影", "电视剧", "剧集", "美剧", "日剧", "韩剧", "英剧", "国产剧", "动漫", "动画", "纪录片", "综艺", "影视", "视频", "下载"
    ]
}
