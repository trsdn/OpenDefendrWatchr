import XCTest

@testable import OpenDefendrWatchrKit

final class ByteFormattingTests: XCTestCase {
    func testCompactUsesOneDecimalForGigabytesAndAbove() {
        // 18.91 GB is the figure from the incident; the menu bar must render it as 18.9G.
        XCTAssertEqual(ByteFormatting.compact(20_303_237_939), "18.9G")
        XCTAssertEqual(ByteFormatting.compact(8 * Fixture.gb), "8.0G")
        XCTAssertEqual(ByteFormatting.compact(1536 * 1024 * 1024 * 1024), "1.5T")
    }

    func testCompactRoundsSmallerUnitsToWholeNumbers() {
        XCTAssertEqual(ByteFormatting.compact(87_824 * 1024), "86M")
        XCTAssertEqual(ByteFormatting.compact(4096), "4K")
        XCTAssertEqual(ByteFormatting.compact(512), "512B")
        XCTAssertEqual(ByteFormatting.compact(0), "0B")
    }

    func testCompactStaysShortEnoughForAMenuBar() {
        // A title that grows without bound would push other menu bar items off screen.
        for bytes in [UInt64(0), 999, 1023, Fixture.gb - 1, 24 * Fixture.gb, 128 * Fixture.gb] {
            XCTAssertLessThanOrEqual(ByteFormatting.compact(bytes).count, 6, "bytes=\(bytes)")
        }
    }

    func testCompactSwitchesUnitExactlyAtTheBoundary() {
        XCTAssertEqual(ByteFormatting.compact(1024 * 1024 - 1), "1024K")
        XCTAssertEqual(ByteFormatting.compact(1024 * 1024), "1M")
    }

    func testDetailedKeepsTwoDecimalsForTickets() {
        XCTAssertEqual(ByteFormatting.detailed(20_303_237_939), "18.91 GB")
        XCTAssertEqual(ByteFormatting.detailed(139_116_544), "132.67 MB")
        XCTAssertEqual(ByteFormatting.detailed(512), "512 bytes")
    }

    func testPercent() {
        XCTAssertEqual(ByteFormatting.percent(0.0842), "8.4%")
        XCTAssertEqual(ByteFormatting.percent(1), "100.0%")
    }
}
