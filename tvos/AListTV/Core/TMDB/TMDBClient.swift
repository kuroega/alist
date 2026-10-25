import CryptoKit
import Foundation

/// Where the TMDB credential comes from and which language metadata uses.
enum TMDBConfiguration {
    /// Name of the optional, git-ignored bundle resource holding `APIKey`.
    static let resourceName = "TMDB.local"

    /// A v3 API key or a v4 read access token, from (in order) the
    /// `TMDB_API_KEY` environment variable or the bundled `TMDB.local.plist`.
    static func apiKey(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let value = environment["TMDB_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        guard let url = bundle.url(forResource: resourceName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = (plist["APIKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// TMDB language tag for the viewer's first preferred language, e.g.
    /// `zh-Hans-CN` → `zh-CN`, `en-GB` → `en-GB`.
    static func language(preferred: [String] = Locale.preferredLanguages) -> String {
        guard let identifier = preferred.first else { return "en-US" }
        let locale = Locale(identifier: identifier)
        guard let code = locale.language.languageCode?.identifier else { return "en-US" }
        if code == "zh" {
            let script = locale.language.script?.identifier
            let region = locale.region?.identifier
            if script == "Hant" || region == "TW" || region == "HK" { return region == "HK" ? "zh-HK" : "zh-TW" }
            return "zh-CN"
        }
        if let region = locale.region?.identifier, region.count == 2 { return "\(code)-\(region)" }
        return code
    }
}

enum TMDBImageSize {
    case poster
    case backdrop
    case still
    case profile
    case logo
    case original

    var pathComponent: String {
        switch self {
        case .poster, .logo: "w500"
        case .backdrop: "w1280"
        case .still: "w780"
        case .profile: "w185"
        case .original: "original"
        }
    }
}

enum TMDBImage {
    static func url(_ path: String?, size: TMDBImageSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size.pathComponent)\(path.hasPrefix("/") ? path : "/" + path)")
    }
}

enum TMDBError: Error, Equatable {
    case missingAPIKey
    case unauthorized
    case notFound
    case rateLimited
    case transport(String)
    case invalidResponse
}

/// Thin TMDB v3 client. Every response is cached on disk, so the Gallery
/// reopens without touching the network and stays within TMDB's rate limits.
///
/// Requests run concurrently: lookups are bound by round-trip latency, not
/// work, so throughput comes from keeping many in flight. A shared gate caps
/// them below TMDB's per-IP limits and merges identical concurrent requests.
final class TMDBClient: Sendable {
    /// Requests in flight at once, across every caller of this client.
    static let maxConcurrentRequests = 20

    /// Our own session: enough connections per host for the gate's limit,
    /// and no URL cache since every response is cached on disk already.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maxConcurrentRequests
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    let language: String
    /// Skips cached responses and asks TMDB again, storing the fresh answers.
    let bypassesCache: Bool
    private let apiKey: String
    private let session: URLSession
    private let cache: TMDBResponseCache
    private let gate: TMDBRequestGate

    convenience init(
        apiKey: String,
        language: String = TMDBConfiguration.language(),
        session: URLSession = TMDBClient.defaultSession,
        cache: TMDBResponseCache = TMDBResponseCache(),
        maxConcurrentRequests: Int = TMDBClient.maxConcurrentRequests
    ) {
        self.init(apiKey: apiKey, language: language, session: session, cache: cache, gate: TMDBRequestGate(limit: maxConcurrentRequests), bypassesCache: false)
    }

    private init(apiKey: String, language: String, session: URLSession, cache: TMDBResponseCache, gate: TMDBRequestGate, bypassesCache: Bool) {
        self.apiKey = apiKey
        self.language = language
        self.session = session
        self.cache = cache
        self.gate = gate
        self.bypassesCache = bypassesCache
    }

    /// The same client, but every request goes to TMDB and refreshes the
    /// cache, for re-fetching one title's metadata on demand.
    func bypassingCache() -> TMDBClient {
        TMDBClient(apiKey: apiKey, language: language, session: session, cache: cache, gate: gate, bypassesCache: true)
    }

    private static func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    /// Searches in the client's language, or in `language` when given.
    func searchMovies(query: String, year: Int?, language: String? = nil) async throws -> [TMDBMovieResult] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        if let year { items.append(URLQueryItem(name: "year", value: String(year))) }
        let page: TMDBPage<TMDBMovieResult> = try await get("/search/movie", items, language: language, maxAge: Self.week)
        return page.results
    }

    func searchShows(query: String, year: Int?, language: String? = nil) async throws -> [TMDBShowResult] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        if let year { items.append(URLQueryItem(name: "first_air_date_year", value: String(year))) }
        let page: TMDBPage<TMDBShowResult> = try await get("/search/tv", items, language: language, maxAge: Self.week)
        return page.results
    }

    func movieGenres() async throws -> [TMDBGenre] {
        let list: TMDBGenreList = try await get("/genre/movie/list", [], maxAge: Self.month)
        return list.genres
    }

    func movie(id: Int) async throws -> TMDBMovieDetail {
        try await get("/movie/\(id)", detailItems(appending: "credits,images,release_dates"), maxAge: Self.week)
    }

    func show(id: Int) async throws -> TMDBShowDetail {
        try await get("/tv/\(id)", detailItems(appending: "credits,images,content_ratings"), maxAge: Self.week)
    }

    /// Artwork in every language, for titles whose localized search result
    /// has no poster or backdrop.
    func images(showID: Int? = nil, movieID: Int? = nil) async throws -> TMDBImageSet {
        let path = showID.map { "/tv/\($0)/images" } ?? "/movie/\(movieID ?? 0)/images"
        let primary = String(language.prefix(2))
        return try await get(path, [URLQueryItem(name: "include_image_language", value: [primary, "en", "null"].uniqued().joined(separator: ","))], maxAge: Self.week)
    }

    func season(showID: Int, number: Int) async throws -> TMDBSeasonDetail {
        try await get("/tv/\(showID)/season/\(number)", [], maxAge: Self.week)
    }

    private func detailItems(appending: String) -> [URLQueryItem] {
        let primary = String(language.prefix(2))
        return [
            URLQueryItem(name: "append_to_response", value: appending),
            URLQueryItem(name: "include_image_language", value: [primary, "en", "null"].uniqued().joined(separator: ","))
        ]
    }

    private static let week: TimeInterval = 7 * 86_400
    private static let month: TimeInterval = 30 * 86_400

    private func get<Response: Decodable>(_ path: String, _ items: [URLQueryItem], language: String? = nil, maxAge: TimeInterval) async throws -> Response {
        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")!
        let queryItems = (items + [URLQueryItem(name: "language", value: language ?? self.language)]).sorted { $0.name < $1.name }
        let cacheKey = path + "?" + queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")

        if !bypassesCache, let data = await cache.data(for: cacheKey, maxAge: maxAge), let decoded = try? Self.decode(Response.self, from: data) {
            return decoded
        }

        // A v4 read access token is a JWT and goes in the header; a v3 key is a query item.
        let usesBearer = apiKey.hasPrefix("eyJ")
        components.queryItems = usesBearer ? queryItems : queryItems + [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components.url else { throw TMDBError.invalidResponse }
        // Even a slow proxied round trip answers well within this; longer only
        // delays noticing that TMDB is unreachable.
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if usesBearer { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        let data: Data
        do {
            let session = session
            data = try await gate.run(key: cacheKey) { try await Self.fetch(request, session: session) }
        } catch let TMDBError.transport(message) {
            if Task.isCancelled { throw CancellationError() }
            // Stale data beats an empty shelf when the network drops, but a
            // forced refresh reports the failure instead of the old answer.
            if !bypassesCache, let stale = await cache.data(for: cacheKey, maxAge: .infinity), let decoded = try? Self.decode(Response.self, from: stale) {
                return decoded
            }
            throw TMDBError.transport(message)
        }
        let decoded: Response
        do {
            decoded = try Self.decode(Response.self, from: data)
        } catch {
            throw TMDBError.invalidResponse
        }
        await cache.store(data, for: cacheKey)
        return decoded
    }

    /// One request, retried while TMDB asks us to slow down. Returns the body
    /// of a successful response.
    private static func fetch(_ request: URLRequest, session: URLSession) async throws -> Data {
        for attempt in 0 ..< 3 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw TMDBError.transport(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw TMDBError.invalidResponse }
            switch http.statusCode {
            case 200 ... 299:
                return data
            case 401:
                throw TMDBError.unauthorized
            case 404:
                throw TMDBError.notFound
            case 429:
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt + 1)
                try await Task.sleep(for: .seconds(min(max(wait, 0.5), 5)))
            default:
                throw TMDBError.transport("TMDB returned HTTP \(http.statusCode).")
            }
        }
        throw TMDBError.rateLimited
    }
}

/// Limits TMDB requests in flight and lets callers that ask for the same
/// request at the same time share one network round trip.
actor TMDBRequestGate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: (id: UUID, task: Task<Data, Error>)] = [:]

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    func run(key: String, _ work: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let shared = inFlight[key] { return try await shared.task.value }
        let id = UUID()
        let task = Task {
            await self.acquire()
            defer { self.release() }
            return try await work()
        }
        inFlight[key] = (id, task)
        let result = await task.result
        if inFlight[key]?.id == id { inFlight[key] = nil }
        return try result.get()
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // The slot is handed over by `release`, so `running` stays counted.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// TMDB JSON responses on disk under Caches, keyed by request.
actor TMDBResponseCache {
    private let directory: URL?

    init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("TMDB", isDirectory: true)) {
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func data(for key: String, maxAge: TimeInterval) -> Data? {
        guard let url = fileURL(for: key),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) <= maxAge else { return nil }
        return try? Data(contentsOf: url)
    }

    func store(_ data: Data, for key: String) {
        guard let url = fileURL(for: key) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(digest + ".json")
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
