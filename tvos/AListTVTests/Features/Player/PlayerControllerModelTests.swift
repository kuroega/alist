import Foundation
import XCTest
@testable import AListTV

final class PlayerControllerModelTests: XCTestCase {
    func testSeekTargetClampsAtZeroAndDuration() {
        XCTAssertEqual(PlaybackPresentation.clampedSeekTarget(-10, duration: 120), 0)
        XCTAssertEqual(PlaybackPresentation.clampedSeekTarget(130, duration: 120), 120)
        XCTAssertEqual(PlaybackPresentation.clampedSeekTarget(42, duration: 120), 42)
        XCTAssertEqual(PlaybackPresentation.clampedSeekTarget(-10, duration: 0), 0)
    }

    func testProgressFractionClampsToTimelineBounds() {
        XCTAssertEqual(PlaybackPresentation.clampedProgressFraction(-10, duration: 120), 0)
        XCTAssertEqual(PlaybackPresentation.clampedProgressFraction(60, duration: 120), 0.5)
        XCTAssertEqual(PlaybackPresentation.clampedProgressFraction(130, duration: 120), 1)
        XCTAssertEqual(PlaybackPresentation.clampedProgressFraction(60, duration: 0), 0)
    }

    func testScrubTargetUsesHorizontalTranslationAndClamps() {
        XCTAssertEqual(
            PlaybackPresentation.scrubTarget(currentTime: 45, horizontalTranslation: 30, duration: 120),
            55
        )
        XCTAssertEqual(
            PlaybackPresentation.scrubTarget(currentTime: 45, horizontalTranslation: -150, duration: 120),
            0
        )
        XCTAssertEqual(
            PlaybackPresentation.scrubTarget(currentTime: 115, horizontalTranslation: 60, duration: 120),
            120
        )
    }

    func testResumeTimeTextIncludesHours() {
        XCTAssertEqual(PlaybackPresentation.resumeTimeText(0), "00:00:00")
        XCTAssertEqual(PlaybackPresentation.resumeTimeText(3_723), "01:02:03")
    }

    func testTrackLabelFallsBackAndExcludesURLLikeMetadata() {
        XCTAssertEqual(
            PlaybackPresentation.trackTitle(name: nil, description: nil, language: nil, fallback: "Audio 1"),
            "Audio 1"
        )
        XCTAssertEqual(
            PlaybackPresentation.trackTitle(name: " https://media.example/sub.srt?token=secret ", description: "Commentary", language: "en", fallback: "Subtitle 1"),
            "Commentary"
        )
        XCTAssertEqual(
            PlaybackPresentation.trackTitle(name: "English", description: "Commentary", language: "en", fallback: "Audio 1"),
            "English"
        )
    }

    func testFrameRateGuardsZeroDenominator() {
        XCTAssertNil(PlaybackPresentation.frameRate(numerator: 24, denominator: 0))
        XCTAssertEqual(PlaybackPresentation.frameRate(numerator: 24_000, denominator: 1_001)!, 23.976023976023978, accuracy: 0.000_001)
    }

    func testDiagnosticsFormattingHandlesAbsentMetadata() {
        XCTAssertEqual(PlaybackPresentation.diagnosticMetadata(nil, nil, nil), "—")
        XCTAssertEqual(PlaybackPresentation.diagnosticMetadata("English", "en", "AAC"), "English · en · AAC")
        XCTAssertEqual(PlaybackPresentation.diagnosticBitrate(125_000), "1.00 Mbit/s")
    }

    func testSeekTargetClampsUnknownDurationNegative() {
        XCTAssertEqual(PlaybackPresentation.clampedSeekTarget(-5, duration: 0), 0)
        XCTAssertEqual(PlaybackPresentation.clampedSeekTarget(999, duration: 0), 999)
    }

    func testTrackTitleFiltersQueryStrings() {
        XCTAssertEqual(
            PlaybackPresentation.trackTitle(name: nil, description: "cdn.example.com?token=abc", language: "en", fallback: "Sub 1"),
            "en"
        )
    }

    func testDiagnosticBitrateConversion() {
        XCTAssertEqual(PlaybackPresentation.diagnosticBitrate(0), "0.00 Mbit/s")
    }

    func testDiagnosticMetadataPartialValues() {
        XCTAssertEqual(PlaybackPresentation.diagnosticMetadata("English", nil, "AAC"), "English · AAC")
        XCTAssertEqual(PlaybackPresentation.diagnosticMetadata(nil, "en", nil), "en")
    }
}
