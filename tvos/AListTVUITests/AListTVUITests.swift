import XCTest

final class AListTVUITests: XCTestCase {
    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        let fixtureUsername = name.contains("OTPChallenge") ? "otp" : "alice"
        app.launchArguments.append(contentsOf: [
            "ui-testing",
            "ui-server=https://alist.example",
            "ui-username=\(fixtureUsername)",
            "ui-password=password",
            "ui-otp=123456"
        ])
        app.launch()
    }

    func testLoginThenBrowseRoot() {
        login(username: "alice")
        XCTAssertTrue(app.buttons["browser.item./Shows"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["browser.item./Sample.mp4"].exists)
    }

    func testSwitchesBetweenCardAndListViews() {
        login(username: "alice")
        let viewMode = app.buttons["browser.view-mode"]
        XCTAssertTrue(viewMode.waitForExistence(timeout: 3))
        let initialLabel = viewMode.label
        XCTAssertTrue(["List view", "Card view"].contains(initialLabel))

        focusAndSelect(viewMode, direction: .up)

        XCTAssertNotEqual(app.buttons["browser.view-mode"].label, initialLabel)
        XCTAssertTrue(app.buttons["browser.item./Shows"].exists)
    }

    func testSortMenuShowsCriteriaAndDirection() {
        login(username: "alice")
        let sort = app.buttons["browser.sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 3))

        focusAndSelect(sort, direction: .up)

        XCTAssertTrue(app.buttons["Name"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Modified date"].exists)
        XCTAssertTrue(app.buttons["Size"].exists)
        XCTAssertTrue(app.buttons["Ascending"].exists || app.buttons["Descending"].exists)
    }

    func testOTPChallengeThenLogin() {
        loginForm(username: "otp")
        focusAndSelect(app.buttons["connection.connect"], direction: .down)
        let otp = app.textFields["connection.otp"]
        XCTAssertTrue(otp.waitForExistence(timeout: 3))
        XCTAssertEqual(otp.value as? String, "123456")
        let verify = app.buttons["connection.verify"]
        if !verify.hasFocus { remote.press(.down) }
        if !verify.hasFocus { remote.press(.right) }
        XCTAssertTrue(verify.hasFocus)
        remote.press(.select)
        XCTAssertTrue(app.buttons["browser.item./Shows"].waitForExistence(timeout: 3))
    }

    func testLogoutReturnsToConnection() {
        login(username: "alice")
        let logout = app.buttons["browser.logout"]
        XCTAssertTrue(logout.waitForExistence(timeout: 3))
        focusAndSelect(logout, direction: .up)
        let server = app.textFields["connection.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 3))
        XCTAssertEqual(server.value as? String, "https://alist.example")
        XCTAssertEqual(app.textFields["connection.username"].value as? String, "alice")
        XCTAssertEqual(app.secureTextFields["connection.password"].value as? String, "Password")
        XCTAssertFalse(app.buttons["browser.item./Shows"].exists)
    }

    func testOpenVideoThenReturnRestoresFocus() {
        login(username: "alice")
        let video = app.buttons["browser.item./Sample.mp4"]
        XCTAssertTrue(video.waitForExistence(timeout: 3))
        focusAndSelect(video, direction: .right)
        let done = app.buttons["player.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        remote.press(.menu)
        XCTAssertTrue(video.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "value == 'focused'"), evaluatedWith: video)
        waitForExpectations(timeout: 3)
    }

    func testVisibleSeekButtonsMoveExactlyTenSeconds() {
        openFixturePlayer()
        let currentTime = app.staticTexts["player.current-time"]
        let rewind = app.buttons["player.seek-backward-10"]
        let forward = app.buttons["player.seek-forward-10"]
        let playPause = app.buttons["player.play-pause"]
        let progress = app.descendants(matching: .any)["player.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(progress.frame.width, 500)
        XCTAssertTrue(currentTime.waitForExistence(timeout: 3))
        XCTAssertTrue(playPause.waitForExistence(timeout: 3))
        XCTAssertTrue(playPause.hasFocus)
        remote.press(.right)
        waitForFocus(rewind)
        remote.press(.select)
        XCTAssertEqual(currentTime.label, "00:35")
        focus(forward, direction: .right)
        remote.press(.select)
        XCTAssertEqual(currentTime.label, "00:45")
    }
    func testSubtitleSelectionJourney() {
        openFixturePlayer()
        let subtitles = app.buttons["player.subtitles"]
        let playPause = app.buttons["player.play-pause"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 3))
        XCTAssertTrue(playPause.waitForExistence(timeout: 3))
        XCTAssertTrue(playPause.hasFocus)

        // Navigate to subtitles button and open dialog
        focus(subtitles, direction: .right)
        remote.press(.select)

        // Verify all options exist
        XCTAssertTrue(dialogButton(containing: "Off").waitForExistence(timeout: 3))
        XCTAssertTrue(dialogButton(containing: "English · en · WebVTT").exists, "Embedded subtitle should exist")
        XCTAssertTrue(dialogButton(containing: "Sample.zh.srt").exists, "External subtitle Sample.zh.srt should exist")
        XCTAssertTrue(dialogButton(containing: "Unrelated.ass").exists, "External subtitle Unrelated.ass should exist")

        // Select Off
        let offBtn = dialogButton(containing: "Off")
        focus(offBtn, direction: .up)
        remote.press(.select)

        // Reopen dialog and verify Off is selected
        waitForFocus(subtitles)
        remote.press(.select)
        XCTAssertTrue(dialogButton(containing: "Off").waitForExistence(timeout: 3))
        assertDialogSelection("Off", file: #file, line: #line)

        // Select embedded English
        let embeddedBtn = dialogButton(containing: "English · en · WebVTT")
        focus(embeddedBtn, direction: .down)
        remote.press(.select)

        // Reopen dialog and verify English is selected
        waitForFocus(subtitles)
        remote.press(.select)
        XCTAssertTrue(dialogButton(containing: "English · en · WebVTT").waitForExistence(timeout: 3))
        assertDialogSelection("English · en · WebVTT", file: #file, line: #line)

        // Select Sample.zh.srt
        let sampleBtn = dialogButton(containing: "Sample.zh.srt")
        focus(sampleBtn, direction: .down)
        remote.press(.select)

        // Reopen dialog and verify Sample.zh.srt is selected
        waitForFocus(subtitles)
        remote.press(.select)
        XCTAssertTrue(dialogButton(containing: "Sample.zh.srt").waitForExistence(timeout: 3))
        assertDialogSelection("Sample.zh.srt", file: #file, line: #line)

        // Select Unrelated.ass
        let unrelatedBtn = dialogButton(containing: "Unrelated.ass")
        focus(unrelatedBtn, direction: .down)
        remote.press(.select)

        // Reopen dialog and verify Unrelated.ass is selected
        waitForFocus(subtitles)
        remote.press(.select)
        XCTAssertTrue(dialogButton(containing: "Unrelated.ass").waitForExistence(timeout: 3))
        assertDialogSelection("Unrelated.ass", file: #file, line: #line)
    }

    func testAudioSelectionJourney() {
        openFixturePlayer()
        let audio = app.buttons["player.audio"]
        let playPause = app.buttons["player.play-pause"]
        XCTAssertTrue(audio.waitForExistence(timeout: 3))
        XCTAssertTrue(playPause.waitForExistence(timeout: 3))
        XCTAssertTrue(playPause.hasFocus)

        // Navigate to audio button and open dialog
        focus(audio, direction: .right)
        remote.press(.select)

        // Verify both tracks exist
        XCTAssertTrue(dialogButton(containing: "English · en · AAC").waitForExistence(timeout: 3))
        XCTAssertTrue(dialogButton(containing: "Chinese · zh · AAC").exists)

        // Select English (should already be selected)
        let englishBtn = dialogButton(containing: "English · en · AAC")
        focus(englishBtn, direction: .up)
        remote.press(.select)

        // Reopen dialog and verify English is selected
        waitForFocus(audio)
        remote.press(.select)
        XCTAssertTrue(dialogButton(containing: "English · en · AAC").waitForExistence(timeout: 3))
        assertDialogSelection("English · en · AAC", file: #file, line: #line)

        // Move to Chinese and select
        let chineseBtn = dialogButton(containing: "Chinese · zh · AAC")
        focus(chineseBtn, direction: .down)
        remote.press(.select)

        // Reopen dialog and verify Chinese is selected
        waitForFocus(audio)
        remote.press(.select)
        XCTAssertTrue(dialogButton(containing: "Chinese · zh · AAC").waitForExistence(timeout: 3))
        assertDialogSelection("Chinese · zh · AAC", file: #file, line: #line)
    }

    private func dialogButton(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func assertDialogSelection(_ expectedText: String, file: StaticString, line: UInt) {
        let selected = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '✓'")).allElementsBoundByIndex
        let selectedLabels = selected.filter { $0.exists }.map(\.label)
        XCTAssertTrue(
            selectedLabels.contains(where: { $0.contains(expectedText) }),
            "Expected '\(expectedText)' to be selected (✓), but selected items are: \(selectedLabels)",
            file: file, line: line
        )
    }
    func testDiagnosticsToggleJourney() {
        openFixturePlayer()
        let toggle = app.buttons["player.diagnostics-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))

        // Navigate to diagnostics toggle via right presses from default playPause focus
        // Order: playPause -> rewind -> forward -> subtitles -> audio -> diagnostics
        remote.press(.right)  // -> rewind
        remote.press(.right)  // -> forward
        remote.press(.right)  // -> subtitles
        remote.press(.right)  // -> audio
        remote.press(.right)  // -> diagnostics-toggle
        XCTAssertTrue(toggle.hasFocus)
        remote.press(.select)  // Toggle on

        let panel = app.descendants(matching: .any)["player.diagnostics"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))

        let diagnosticsTree = panel.debugDescription
        XCTAssertTrue(diagnosticsTree.contains("1920×1080") || diagnosticsTree.contains("1920\u{00d7}1080"), "Resolution should be visible")
        XCTAssertTrue(diagnosticsTree.contains("H.264"), "Video codec should be visible")
        XCTAssertTrue(diagnosticsTree.contains("AAC"), "Audio codec should be visible")
        XCTAssertTrue(diagnosticsTree.contains("English"), "English audio metadata should be visible")
        for sensitiveValue in ["http://", "https://", "?", "token", "cookie", "header", "media.example"] {
            XCTAssertFalse(diagnosticsTree.localizedCaseInsensitiveContains(sensitiveValue), "Sensitive value leaked: \(sensitiveValue)")
        }

        // Toggle off
        remote.press(.select)
        XCTAssertFalse(panel.exists)
    }

    private func openFixturePlayer() {
        login(username: "alice")
        let video = app.buttons["browser.item./Sample.mp4"]
        XCTAssertTrue(video.waitForExistence(timeout: 3))
        focusAndSelect(video, direction: .right)
        XCTAssertTrue(app.buttons["player.seek-backward-10"].waitForExistence(timeout: 3))
    }

    private func login(username: String) {
        loginForm(username: username)
        focusAndSelect(app.buttons["connection.connect"], direction: .down)
    }

    private func loginForm(username: String) {
        let server = app.textFields["connection.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 3))
        XCTAssertEqual(server.value as? String, "https://alist.example")
        let usernameField = app.textFields["connection.username"]
        XCTAssertTrue(usernameField.exists)
        XCTAssertEqual(usernameField.value as? String, username)
        let password = app.secureTextFields["connection.password"]
        XCTAssertTrue(password.exists)
    }



    private func focusAndSelect(
        _ element: XCUIElement,
        direction: XCUIRemote.Button
    ) {
        focus(element, direction: direction)
        remote.press(.select)
    }

    private func waitForFocus(_ element: XCUIElement) {
        let deadline = Date().addingTimeInterval(3)
        while !element.hasFocus && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(element.hasFocus, app.debugDescription)
    }

    private func focus(_ element: XCUIElement, direction: XCUIRemote.Button) {
        for candidate in [direction, .down, .up, .right, .left] {
            for _ in 0..<8 where !element.hasFocus {
                remote.press(candidate)
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        XCTAssertTrue(element.hasFocus, "Could not focus \(element)")
    }
}
