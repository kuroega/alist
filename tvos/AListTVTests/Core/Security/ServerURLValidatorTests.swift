import XCTest
@testable import AListTV

final class ServerURLValidatorTests: XCTestCase {
    func testAcceptsHTTPSAndNormalizesTrailingSlashes() throws {
        XCTAssertEqual(
            try ServerURLValidator.validate("  https://alist.example:8443/prefix///  ").absoluteString,
            "https://alist.example:8443/prefix"
        )
        XCTAssertEqual(
            try ServerURLValidator.validate("https://alist.example/").absoluteString,
            "https://alist.example"
        )
    }

#if DEBUG
    func testAcceptsHTTPOnlyForPrivateDebugServers() throws {
        XCTAssertEqual(
            try ServerURLValidator.validate("http://10.0.0.2:5244/").absoluteString,
            "http://10.0.0.2:5244"
        )
        XCTAssertEqual(
            try ServerURLValidator.validate("http://media-server.local:5244").absoluteString,
            "http://media-server.local:5244"
        )
        assertError(.insecureURL, value: "http://203.0.113.1:5244")
        assertError(.insecureURL, value: "http://10.0.0.1.example.com:5244")
        assertError(.insecureURL, value: "http://fc.example.com:5244")
    }
#endif

    func testRejectsHTTPAndRelativeURLs() {
        assertError(.insecureURL, value: "http://alist.example")
        assertError(.invalidServerURL, value: "/relative/path")
        assertError(.invalidServerURL, value: "alist.example")
    }

    func testRejectsMissingHostCredentialsQueryAndFragment() {
        assertError(.invalidServerURL, value: "https:///path")
        assertError(.invalidServerURL, value: "https://user:password@alist.example")
        assertError(.invalidServerURL, value: "https://alist.example?query=value")
        assertError(.invalidServerURL, value: "https://alist.example/#fragment")
    }

    private func assertError(_ expected: AListAPIError, value: String) {
        XCTAssertThrowsError(try ServerURLValidator.validate(value)) { error in
            XCTAssertEqual(error as? AListAPIError, expected)
        }
    }
}
