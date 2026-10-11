import Foundation
import XCTest
@testable import AListTV

final class RecentItemsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var clock: Date!
    private var store: RecentItemsStore!
    private let alice = RecentItemsAccount(baseURL: "https://alist.example", username: "alice")
    private let bob = RecentItemsAccount(baseURL: "https://alist.example", username: "bob")

    override func setUp() {
        super.setUp()
        let suite = "RecentItemsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        store = RecentItemsStore(defaults: defaults, now: { [unowned self] in
            clock = clock.addingTimeInterval(1)
            return clock
        })
    }

    override func tearDown() {
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testNewestFirstAndReopeningMovesToFront() {
        store.recordOpen(file("/a.mp4"), account: alice)
        store.recordOpen(file("/b.mp4"), account: alice)
        store.recordOpen(file("/c.mp3"), account: alice)
        store.recordOpen(file("/a.mp4"), account: alice)

        XCTAssertEqual(paths(for: alice), ["/a.mp4", "/c.mp3", "/b.mp4"])
    }

    func testKeepsFifteenNewestPerAccount() {
        store.recordOpen(file("/bob.mp4"), account: bob)
        for index in 1...20 {
            store.recordOpen(file("/\(index).mp4"), account: alice)
        }

        XCTAssertEqual(RecentItemsStore.limit, 15)
        XCTAssertEqual(paths(for: alice), (6...20).reversed().map { "/\($0).mp4" })
        XCTAssertEqual(paths(for: bob), ["/bob.mp4"])
    }

    func testIgnoresFoldersAndPathlessObjects() {
        store.recordOpen(AListObject(virtualPath: "/Shows", name: "Shows", isDirectory: true), account: alice)
        store.recordOpen(AListObject(virtualPath: nil, name: "orphan.mp4", isDirectory: false), account: alice)
        store.recordOpen(AListObject(virtualPath: "", name: "empty.mp4", isDirectory: false), account: alice)

        XCTAssertTrue(store.items(for: alice).isEmpty)
    }

    func testNormalizesPathsSoDuplicatesCollapse() {
        store.recordOpen(file("//Shows/./E01.mkv"), account: alice)
        store.recordOpen(file("/Shows/E01.mkv"), account: alice)

        XCTAssertEqual(paths(for: alice), ["/Shows/E01.mkv"])
    }

    func testRemoveAndClearOnlyAffectOneAccount() {
        store.recordOpen(file("/a.mp4"), account: alice)
        store.recordOpen(file("/b.mp4"), account: alice)
        store.recordOpen(file("/a.mp4"), account: bob)

        XCTAssertEqual(store.remove(path: "/a.mp4", account: alice).map(\.id), ["/b.mp4"])
        XCTAssertEqual(paths(for: bob), ["/a.mp4"])

        XCTAssertTrue(store.removeAll(account: alice).isEmpty)
        XCTAssertEqual(paths(for: bob), ["/a.mp4"])
    }

    func testPersistsObjectMetadataAcrossInstances() {
        let object = AListObject(
            virtualPath: "/Movies/Film.mkv",
            name: "Film.mkv",
            size: 42,
            isDirectory: false,
            modified: "2026-08-01T00:00:00Z",
            type: AListFileType.video.rawValue,
            thumbnail: "https://alist.example/thumb.jpg"
        )
        store.recordOpen(object, account: alice)

        let reloaded = RecentItemsStore(defaults: defaults).items(for: alice)
        XCTAssertEqual(reloaded.map(\.object), [object])
    }

    private func file(_ path: String) -> AListObject {
        AListObject(virtualPath: path, name: URL(fileURLWithPath: path).lastPathComponent, isDirectory: false)
    }

    private func paths(for account: RecentItemsAccount) -> [String] {
        store.items(for: account).map(\.id)
    }
}

@MainActor
final class RecentsViewModelTests: XCTestCase {
    private let baseURL = URL(string: "https://alist.example")!

    func testEntriesCarryOnlyResumableProgress() {
        let defaults = makeDefaults()
        let progressStore = PlaybackProgressStore(defaults: defaults)
        progressStore.update(identity: identity("/resume.mp4"), position: 600, duration: 2_400)
        progressStore.update(identity: identity("/other-user.mp4", username: "bob"), position: 600, duration: 2_400)
        let store = RecentItemsStore(defaults: defaults)
        let viewModel = makeViewModel(store: store, progressStore: progressStore)

        viewModel.recordOpen(file("/fresh.mp4"))
        viewModel.recordOpen(file("/other-user.mp4"))
        viewModel.recordOpen(file("/resume.mp4"))

        XCTAssertEqual(viewModel.entries.map(\.id), ["/resume.mp4", "/other-user.mp4", "/fresh.mp4"])
        XCTAssertEqual(viewModel.entries[0].progress ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(viewModel.entries[0].remaining, 1_800)
        XCTAssertNil(viewModel.entries[1].progress)
        XCTAssertNil(viewModel.entries[2].progress)
        XCTAssertNil(viewModel.entries[2].remaining)
    }

    func testReloadPicksUpProgressSavedAfterOpening() {
        let defaults = makeDefaults()
        let progressStore = PlaybackProgressStore(defaults: defaults)
        let viewModel = makeViewModel(store: RecentItemsStore(defaults: defaults), progressStore: progressStore)
        viewModel.recordOpen(file("/movie.mp4"))
        XCTAssertNil(viewModel.entries.first?.progress)

        progressStore.update(identity: identity("/movie.mp4"), position: 120, duration: 240)
        viewModel.reload()

        XCTAssertEqual(viewModel.entries.first?.progress ?? 0, 0.5, accuracy: 0.0001)
    }

    func testOpenRemoveAndClear() async throws {
        let defaults = makeDefaults()
        var opened: [String?] = []
        let viewModel = makeViewModel(
            store: RecentItemsStore(defaults: defaults),
            progressStore: PlaybackProgressStore(defaults: defaults),
            onOpen: { opened.append($0.virtualPath) }
        )
        viewModel.recordOpen(file("/a.mp4"))
        viewModel.recordOpen(file("/b.mp4"))

        viewModel.open(viewModel.entries[1])
        let deadline = ContinuousClock.now + .seconds(2)
        while opened.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(opened, ["/a.mp4"])

        viewModel.remove(viewModel.entries[0])
        XCTAssertEqual(viewModel.entries.map(\.id), ["/a.mp4"])
        viewModel.removeAll()
        XCTAssertTrue(viewModel.entries.isEmpty)
    }

    func testFormatting() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(RecentsFormatting.openedAt(now.addingTimeInterval(-20), now: now), "Just now")
        XCTAssertEqual(RecentsFormatting.openedAt(now.addingTimeInterval(30), now: now), "Just now")
        XCTAssertEqual(RecentsFormatting.remaining(20), "Under a minute left")
        XCTAssertEqual(RecentsFormatting.location(for: file("/Sample.mp4")), "Home")
        XCTAssertEqual(RecentsFormatting.location(for: file("/Shows/Season 1/E01.mkv")), "Shows / Season 1")
    }

    private func makeViewModel(
        store: RecentItemsStore,
        progressStore: PlaybackProgressStore,
        onOpen: @escaping @MainActor (AListObject) async -> Void = { _ in }
    ) -> RecentsViewModel {
        RecentsViewModel(store: store, progressStore: progressStore, baseURL: baseURL, username: "alice", onOpen: onOpen)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "RecentsViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func identity(_ path: String, username: String = "alice") -> PlaybackProgressIdentity {
        PlaybackProgressIdentity(baseURL: baseURL.absoluteString, username: username, virtualPath: path)
    }

    private func file(_ path: String) -> AListObject {
        AListObject(virtualPath: path, name: URL(fileURLWithPath: path).lastPathComponent, isDirectory: false)
    }
}
