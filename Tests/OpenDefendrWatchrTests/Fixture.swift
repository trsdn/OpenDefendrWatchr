import XCTest

@testable import OpenDefendrWatchrKit

/// Fixtures modelled on the real 2026-08-22 incident so the numbers under test are the
/// numbers that actually mattered: 24 GB machine, 16 KB pages, wdavdaemon at 18.91 GB.
enum Fixture {
    static let gb: UInt64 = 1024 * 1024 * 1024
    static let totalRAM: UInt64 = 24 * gb
    static let pageSize: UInt64 = 16384

    static func system(freeBytes: UInt64, compressedBytes: UInt64) -> SystemMemoryUsage {
        SystemMemoryUsage(
            totalBytes: totalRAM,
            freeBytes: freeBytes,
            compressedBytes: compressedBytes,
            pageSize: pageSize
        )
    }

    /// A comfortable machine: plenty free, compressor mostly idle.
    static let healthySystem = system(freeBytes: 8 * gb, compressedBytes: 1 * gb)

    /// The state captured in JetsamEvent-2026-08-22-064004.ips:
    /// 8491 free pages of 16 KB (~139 MB) and 571985 compressor pages (~9.4 GB).
    static let jetsamSystem = system(
        freeBytes: 8491 * pageSize,
        compressedBytes: 571_985 * pageSize
    )

    static func sample(
        bytes: UInt64?,
        system: SystemMemoryUsage = healthySystem,
        at seconds: TimeInterval = 0
    ) -> MemorySample {
        MemorySample(
            timestamp: Date(timeIntervalSince1970: seconds),
            process: bytes.map { ProcessMemoryUsage(residentBytes: $0, processCount: 1, pids: [557]) },
            system: system
        )
    }
}

final class FixtureSanityTests: XCTestCase {
    func testJetsamFixtureMatchesTheRecordedIncident() {
        // ~139 MB free, ~9.4 GB compressed — sanity-check the fixture arithmetic itself,
        // because every threshold test below leans on it.
        XCTAssertEqual(Fixture.jetsamSystem.freeBytes, 139_116_544)
        XCTAssertEqual(Fixture.jetsamSystem.compressedBytes, 9_371_402_240)
        XCTAssertLessThan(Fixture.jetsamSystem.freeFraction, 0.01)
        XCTAssertGreaterThan(Fixture.jetsamSystem.compressedFraction, 0.35)
    }
}
