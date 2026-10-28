import Foundation
import XCTest
@testable import AListTV

final class SkipSegmentsTests: XCTestCase {
    func testStoreKeepsEachFolderAndForgetsClearedOnes() {
        let suite = "SkipSegmentsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SkipSegmentsStore(defaults: defaults)
        let show = SkipSegmentsIdentity(baseURL: "https://alist.example", username: "alice", folderPath: "/Show/Season 1")
        let other = SkipSegmentsIdentity(baseURL: "https://alist.example", username: "bob", folderPath: "/Show/Season 1")

        store.save(SkipSegments(opening: 90, ending: 105), for: show)
        XCTAssertEqual(store.segments(for: show), SkipSegments(opening: 90, ending: 105))
        XCTAssertEqual(store.segments(for: other), .none)

        store.save(.none, for: show)
        XCTAssertEqual(store.segments(for: show), .none)
        let remaining = try? PropertyListSerialization.propertyList(from: defaults.data(forKey: SkipSegmentsStore.defaultsKey) ?? Data(), format: nil) as? [Any]
        XCTAssertEqual(remaining?.count, 0)
    }

    func testClampingAndEndingStart() {
        XCTAssertEqual(SkipSegments.clamped(-3), 0)
        XCTAssertEqual(SkipSegments.clamped(89.6), 90)
        XCTAssertEqual(SkipSegments.clamped(5_000), SkipSegments.limit)
        XCTAssertEqual(SkipSegments.clamped(.nan), 0)
        XCTAssertTrue(SkipSegments.canMark(SkipSegments.limit))
        XCTAssertFalse(SkipSegments.canMark(2_585), "a mark 43 minutes from the end would be cut to 20")

        XCTAssertEqual(SkipSegments(opening: 90, ending: 120).endingStart(duration: 1_440), 1_320)
        XCTAssertNil(SkipSegments(opening: 90, ending: 0).endingStart(duration: 1_440))
        XCTAssertNil(SkipSegments(opening: 90, ending: 120).endingStart(duration: 0), "duration not known yet")
        XCTAssertNil(SkipSegments(opening: 90, ending: 120).endingStart(duration: 200), "nothing would be left to watch")
    }
}
