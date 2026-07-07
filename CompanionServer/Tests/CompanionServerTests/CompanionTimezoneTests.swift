import Foundation
import XCTest
@testable import CompanionServer

final class CompanionTimezoneTests: XCTestCase {
    func testResolveUsesConfiguredIdentifier() {
        let timeZone = CompanionTimezone.resolve(identifier: "Asia/Jakarta")
        XCTAssertEqual(timeZone.identifier, "Asia/Jakarta")
    }

    func testResolveFallsBackToCurrentForInvalidIdentifier() {
        let timeZone = CompanionTimezone.resolve(identifier: "Not/A/Timezone")
        XCTAssertEqual(timeZone.identifier, TimeZone.current.identifier)
    }

    func testLocalContextIncludesTimezoneAndOffset() {
        let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        let context = CompanionTimezone.localContext(for: jakarta, now: fixedNow)
        XCTAssertTrue(context.contains("Asia/Jakarta"))
        XCTAssertTrue(context.contains("UTC+7"))
    }

    func testParseCompanionDateTreatsEightPMZuluAsLocalWallClock() {
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        let date = CompanionTimezone.parseCompanionDate("2026-07-08T20:00:00Z", in: jakarta)
        XCTAssertNotNil(date)
        let formatted = CompanionTimezone.formatDate(date!, in: jakarta)
        XCTAssertTrue(formatted.contains("T20:00:00+07:00"))
    }

    func testParseCompanionDateTreatsBareEightPMAsLocal() {
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        let date = CompanionTimezone.parseCompanionDate("2026-07-08T20:00:00", in: jakarta)
        XCTAssertNotNil(date)
        let formatted = CompanionTimezone.formatDate(date!, in: jakarta)
        XCTAssertTrue(formatted.contains("T20:00:00+07:00"))
    }

    func testParseCompanionDateHonorsExplicitOffset() {
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        let date = CompanionTimezone.parseCompanionDate("2026-07-08T20:00:00+08:00", in: jakarta)
        XCTAssertNotNil(date)
        let formatted = CompanionTimezone.formatDate(date!, in: jakarta)
        XCTAssertTrue(formatted.contains("T19:00:00+07:00"))
    }

    func testHasExplicitTimeZoneAcceptsOffsetAndZ() {
        XCTAssertTrue(CompanionTimezone.hasExplicitTimeZone("2026-07-08T15:00:00+08:00"))
        XCTAssertTrue(CompanionTimezone.hasExplicitTimeZone("2026-07-08T07:00:00Z"))
        XCTAssertFalse(CompanionTimezone.hasExplicitTimeZone("2026-07-08T15:00:00"))
    }

    func testIso8601OffsetForJakarta() {
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertEqual(CompanionTimezone.iso8601Offset(for: jakarta, at: fixedNow), "+07:00")
    }
}
