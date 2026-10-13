import SwiftUI
import UIKit

/// Downloads, decodes and caches artwork. TMDB image URLs never change, so
/// responses are served from a large disk cache and decoded images from memory.
final class ArtworkPipeline: @unchecked Sendable {
    static let shared = ArtworkPipeline()

    private let memory = NSCache<NSURL, UIImage>()
    private let diskCache: URLCache
    private let session: URLSession
    private let inflight = InflightImages()

    private init() {
        memory.totalCostLimit = 220 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Artwork", isDirectory: true)
        diskCache = URLCache(memoryCapacity: 24 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024, directory: directory)
        configuration.urlCache = diskCache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        return await inflight.run(url) { [session, memory] in
            guard let result = try? await session.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = UIImage(data: result.0) else { return nil }
            // Decode off the main thread so scrolling never stalls on JPEG work.
            let prepared = await decoded.byPreparingForDisplay() ?? decoded
            let cost = Int(prepared.size.width * prepared.size.height * prepared.scale * prepared.scale * 4)
            memory.setObject(prepared, forKey: url as NSURL, cost: cost)
            return prepared
        }
    }

    /// Drops every downloaded image so artwork is fetched again.
    func removeAll() {
        memory.removeAllObjects()
        diskCache.removeAllCachedResponses()
    }

    func prefetch(_ urls: [URL]) {
        for url in urls where cached(url) == nil {
            Task.detached(priority: .utility) { _ = await self.image(for: url) }
        }
    }
}

/// Coalesces concurrent requests for the same image.
private actor InflightImages {
    private var tasks: [URL: Task<UIImage?, Never>] = [:]

    func run(_ url: URL, _ work: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
        if let existing = tasks[url] { return await existing.value }
        let task = Task { await work() }
        tasks[url] = task
        let image = await task.value
        tasks[url] = nil
        return image
    }
}

/// Remote artwork that fades in over a placeholder, showing cached images
/// synchronously so reused cells never flash.
struct ArtworkImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: LoadedImage?

    private struct LoadedImage: Equatable {
        let url: URL
        let image: UIImage
    }

    var body: some View {
        let image = currentImage
        ZStack {
            if image == nil {
                placeholder()
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url, currentImage == nil else { return }
            guard let image = await ArtworkPipeline.shared.image(for: url), !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { loaded = LoadedImage(url: url, image: image) }
        }
    }

    private var currentImage: UIImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return ArtworkPipeline.shared.cached(url)
    }
}

extension ArtworkImage where Placeholder == Color {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.init(url: url, contentMode: contentMode) { Color.clear }
    }
}

// MARK: - Generated artwork

/// A typographic poster for titles TMDB does not know: a deep two-tone
/// gradient picked from the title, with the name set like a film one-sheet.
struct GeneratedPoster: View {
    let title: String
    var subtitle: String?
    var compact = false

    var body: some View {
        let palette = GalleryPalette.colors(for: title)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 320)
            Image(systemName: "film")
                .font(.system(size: compact ? 90 : 150, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.08))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: 24, y: -10)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: compact ? 26 : 30, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(compact ? 16 : 20)
        }
        .accessibilityHidden(true)
    }
}

enum GalleryPalette {
    /// Stable, rich color pairs so a title keeps its color across launches.
    static func colors(for seed: String) -> (Color, Color) {
        let pairs: [(Color, Color)] = [
            (Color(red: 0.16, green: 0.20, blue: 0.42), Color(red: 0.05, green: 0.06, blue: 0.14)),
            (Color(red: 0.38, green: 0.14, blue: 0.22), Color(red: 0.10, green: 0.04, blue: 0.08)),
            (Color(red: 0.10, green: 0.32, blue: 0.34), Color(red: 0.03, green: 0.09, blue: 0.11)),
            (Color(red: 0.36, green: 0.24, blue: 0.10), Color(red: 0.10, green: 0.06, blue: 0.03)),
            (Color(red: 0.26, green: 0.15, blue: 0.40), Color(red: 0.07, green: 0.04, blue: 0.12)),
            (Color(red: 0.14, green: 0.30, blue: 0.18), Color(red: 0.03, green: 0.08, blue: 0.05))
        ]
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return pairs[Int(hash % UInt64(pairs.count))]
    }

    static func genreTint(_ id: Int) -> Color {
        switch id {
        case 28, 10752: Color(red: 0.85, green: 0.30, blue: 0.22)       // Action, War
        case 12, 37: Color(red: 0.90, green: 0.58, blue: 0.20)           // Adventure, Western
        case 16, 10751: Color(red: 0.30, green: 0.70, blue: 0.95)        // Animation, Family
        case 35: Color(red: 0.98, green: 0.78, blue: 0.25)               // Comedy
        case 80, 53: Color(red: 0.55, green: 0.55, blue: 0.62)           // Crime, Thriller
        case 99, 36: Color(red: 0.62, green: 0.52, blue: 0.40)           // Documentary, History
        case 18: Color(red: 0.62, green: 0.40, blue: 0.85)               // Drama
        case 14: Color(red: 0.45, green: 0.38, blue: 0.95)               // Fantasy
        case 27: Color(red: 0.70, green: 0.10, blue: 0.16)               // Horror
        case 10402: Color(red: 0.95, green: 0.35, blue: 0.62)            // Music
        case 9648: Color(red: 0.32, green: 0.42, blue: 0.70)             // Mystery
        case 10749: Color(red: 0.95, green: 0.42, blue: 0.48)            // Romance
        case 878: Color(red: 0.20, green: 0.80, blue: 0.82)              // Science Fiction
        default: Theme.accent
        }
    }
}

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass on tvOS 26 and later; a frosted material with a hairline
    /// edge on earlier systems.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(tvOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .black).opacity(tint == nil ? 0.25 : 0.35), in: shape)
                .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
        }
    }
}

/// Small glass capsule for quality and status badges ("4K", "Dolby Vision").
struct GlassBadge: View {
    let text: String
    var systemImage: String?
    var emphasized = false

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .bold))
            }
            Text(text)
                .font(.system(size: 19, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(.white.opacity(emphasized ? 1 : 0.9))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .liquidGlass(in: Capsule(), tint: emphasized ? Theme.accent.opacity(0.45) : nil)
    }
}

/// Thin progress line used on cards and episode stills.
struct GalleryProgressBar: View {
    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule()
                    .fill(.white)
                    .frame(width: max(height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

enum GalleryFormat {
    static func runtime(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    static func remaining(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "Under a minute left" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes) min left" }
        return "\(minutes / 60) hr \(minutes % 60) min left"
    }

    static func rating(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(format: "%.1f", value)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func airDate(_ raw: String?) -> String? {
        guard let raw, let date = dayFormatter.date(from: raw) else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func qualityIcon(_ badge: String) -> String? {
        switch badge {
        case "4K": "4k.tv"
        case "Dolby Vision", "HDR": "sun.max"
        case "Atmos", "DTS": "hifispeaker.2"
        default: nil
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
