import XCTest
@testable import AListTV

final class SubtitleAppearanceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "SubtitleAppearanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }

    func testDefaultAppearanceUsesReadableVLCOptions() {
        XCTAssertEqual(SubtitleAppearance.default.vlcMediaOptions, [
            ":freetype-font=Helvetica Neue",
            ":freetype-color=#FFFFFF",
            ":freetype-opacity=255"
        ])
    }

    func testVLCOptionsReflectFontColorAndOpacityChoices() {
        let appearance = SubtitleAppearance(font: .monospace, color: .cyan, opacity: .medium)

        XCTAssertEqual(appearance.vlcMediaOptions, [
            ":freetype-font=Menlo",
            ":freetype-color=#00FFFF",
            ":freetype-opacity=128"
        ])
    }

    func testStoreRoundTripsAppearance() {
        let store = SubtitleAppearanceStore(defaults: defaults)
        let appearance = SubtitleAppearance(font: .serif, color: .yellow, opacity: .high)

        store.save(appearance)

        XCTAssertEqual(store.load(), appearance)
    }

    func testStoreFallsBackForMalformedPayload() {
        defaults.set(Data("not json".utf8), forKey: "com.alist.tv.subtitle-appearance-v1")

        XCTAssertEqual(SubtitleAppearanceStore(defaults: defaults).load(), .default)
    }
}
