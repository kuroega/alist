import Foundation
import XCTest
@testable import AListTV

/// An in-memory AList server whose folders can change between scans.
actor FakeLibraryServer: AListAPI {
    private var folders: [String: [AListObject]] = [:]
    private var unreadable = Set<String>()
    private(set) var listed: [String] = []

    func setFolder(_ path: String, _ children: [AListObject]) { folders[path] = children }
    func removeFolder(_ path: String) { folders[path] = nil }
    func setUnreadable(_ path: String, _ isUnreadable: Bool) {
        if isUnreadable { unreadable.insert(path) } else { unreadable.remove(path) }
    }
    func resetListed() { listed = [] }

    func login(username: String, password: String, otpCode: String?) async throws -> LoginData { throw AListAPIError.invalidResponse }
    func currentUser() async throws -> CurrentUser { throw AListAPIError.invalidResponse }
    func get(path: String) async throws -> FileDetail { throw AListAPIError.invalidResponse }

    func list(path: String, page: Int, perPage: Int, refresh: Bool) async throws -> DirectoryPage {
        listed.append(path)
        if unreadable.contains(path) { throw AListAPIError.transport(message: "Folder is offline") }
        guard let content = folders[path] else { throw AListAPIError.server(code: 500, message: "object not found") }
        return DirectoryPage(content: content, hasMore: false, page: page, perPage: perPage)
    }
}

enum GalleryFixtures {
    static func folder(_ path: String, modified: String = "2026-01-01T00:00:00Z") -> AListObject {
        AListObject(virtualPath: path, name: String(path.split(separator: "/").last ?? ""), isDirectory: true, modified: modified, type: AListFileType.folder.rawValue)
    }

    static func video(_ path: String, size: Int64 = 1_000_000) -> AListObject {
        AListObject(virtualPath: path, name: String(path.split(separator: "/").last ?? ""), size: size, isDirectory: false, modified: "2026-01-02T00:00:00Z", type: AListFileType.video.rawValue)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// /Movies/{Interstellar (2014), Arrival (2016)} and /TV/Dark/Season 1.
    static func populate(_ server: FakeLibraryServer) async {
        await server.setFolder("/Movies", [
            folder("/Movies/Interstellar (2014)"),
            folder("/Movies/Arrival (2016)")
        ])
        await server.setFolder("/Movies/Interstellar (2014)", [
            video("/Movies/Interstellar (2014)/Interstellar.2014.2160p.mkv"),
            AListObject(virtualPath: "/Movies/Interstellar (2014)/Interstellar.2014.srt", name: "Interstellar.2014.srt", isDirectory: false)
        ])
        await server.setFolder("/Movies/Arrival (2016)", [video("/Movies/Arrival (2016)/Arrival.2016.1080p.mkv")])
        await server.setFolder("/TV", [folder("/TV/Dark")])
        await server.setFolder("/TV/Dark", [folder("/TV/Dark/Season 1")])
        await server.setFolder("/TV/Dark/Season 1", [
            video("/TV/Dark/Season 1/Dark.S01E01.mkv"),
            video("/TV/Dark/Season 1/Dark.S01E02.mkv")
        ])
    }
}

/// Collects what a scan hands over.
final class ScanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _upserted: [String: LibraryFile] = [:]
    private var _removed = Set<String>()

    var upserted: [String: LibraryFile] { lock.lock(); defer { lock.unlock() }; return _upserted }
    var removed: Set<String> { lock.lock(); defer { lock.unlock() }; return _removed }

    func record(_ change: LibraryChange) {
        lock.lock()
        for path in change.removed { _removed.insert(path); _upserted[path] = nil }
        for (path, file) in change.upserted { _upserted[path] = file; _removed.remove(path) }
        lock.unlock()
    }
}
