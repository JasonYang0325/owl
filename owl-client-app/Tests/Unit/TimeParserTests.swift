import XCTest
@testable import OWLBrowserLib

/// Unit tests for the `parseTime` function.
final class TimeParserTests: XCTestCase {

    // MARK: - Relative time

    func testRelativeMinutes() {
        let now = Date().timeIntervalSince1970
        guard let result = parseTime("30m") else {
            return XCTFail("parseTime(\"30m\") returned nil")
        }
        // Should be approximately now - 1800 seconds
        let expected = now - 30 * 60
        XCTAssertEqual(result, expected, accuracy: 2.0,
            "30m should parse to ~now minus 1800s")
    }

    func testRelativeDays() {
        let now = Date().timeIntervalSince1970
        guard let result = parseTime("7d") else {
            return XCTFail("parseTime(\"7d\") returned nil")
        }
        let expected = now - 7 * 86400
        XCTAssertEqual(result, expected, accuracy: 2.0,
            "7d should parse to ~now minus 7 days")
    }

    // MARK: - Unix timestamp

    func testUnixTimestampZero() {
        let result = parseTime("0")
        XCTAssertNotNil(result, "Unix timestamp 0 (epoch) should be accepted")
        XCTAssertEqual(result, 0.0, "Unix timestamp 0 should return 0.0")
    }

    // MARK: - ISO 8601

    func testISO8601() {
        let result = parseTime("2024-01-15T10:30:00Z")
        XCTAssertNotNil(result, "ISO 8601 string should be parsed")
        // 2024-01-15T10:30:00Z = 1705314600
        XCTAssertEqual(result!, 1705314600, accuracy: 1.0)
    }

    // MARK: - Invalid input

    func testInvalidInput() {
        XCTAssertNil(parseTime("abc"), "Non-numeric, non-relative input should return nil")
        XCTAssertNil(parseTime(""), "Empty string should return nil")
        XCTAssertNil(parseTime("xyz123"), "Random string should return nil")
    }

    // MARK: - Boundary: relative hours

    func testRelativeHours() {
        let now = Date().timeIntervalSince1970
        guard let result = parseTime("2h") else {
            return XCTFail("parseTime(\"2h\") returned nil")
        }
        let expected = now - 2 * 3600
        XCTAssertEqual(result, expected, accuracy: 2.0,
            "2h should parse to ~now minus 7200s")
    }

    // MARK: - Boundary: zero relative offset

    func testRelativeZeroMinutes() {
        let now = Date().timeIntervalSince1970
        guard let result = parseTime("0m") else {
            return XCTFail("parseTime(\"0m\") returned nil")
        }
        XCTAssertEqual(result, now, accuracy: 2.0,
            "0m should parse to ~now (zero offset)")
    }

    // MARK: - Boundary: negative timestamp

    func testNegativeTimestamp() {
        XCTAssertNil(parseTime("-1"),
            "Negative timestamp should return nil (invalid)")
    }

    // MARK: - Boundary: large timestamp

    func testLargeTimestamp() {
        let result = parseTime("9999999999")
        XCTAssertNotNil(result, "Large numeric timestamp should be accepted")
        XCTAssertEqual(result!, 9999999999.0, accuracy: 0.001,
            "Large timestamp should return 9999999999.0")
    }

    // MARK: - Boundary: whitespace input

    func testWhitespaceInput() {
        XCTAssertNil(parseTime(" "),
            "Single space should return nil")
        XCTAssertNil(parseTime("\t"),
            "Tab character should return nil")
    }
}
