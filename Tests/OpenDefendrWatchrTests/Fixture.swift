import XCTest

@testable import OpenDefendrWatchrKit

/// Fixtures modelled on the real 2026-08-22 incident so the numbers under test are the
/// numbers that actually mattered: 24 GB machine, 16 KB pages, wdavdaemon at 18.91 GB.
enum Fixture {
    static let gb: UInt64 = 1024 * 1024 * 1024
    static let totalRAM: UInt64 = 24 * gb
    static let pageSize: UInt64 = 16384

    static func system(
        freeBytes: UInt64,
        compressedBytes: UInt64,
        available: Double? = 0.46,
        kernelRaw: MemoryPressureLevel = .warning
    ) -> SystemMemoryUsage {
        SystemMemoryUsage(
            totalBytes: totalRAM,
            freeBytes: freeBytes,
            compressedBytes: compressedBytes,
            pageSize: pageSize,
            availableFraction: available,
            kernelPressureLevel: kernelRaw
        )
    }

    /// A comfortable machine: plenty free, compressor mostly idle.
    static let healthySystem = system(freeBytes: 8 * gb, compressedBytes: 1 * gb, available: 0.46)

    /// The state captured in the morning JetsamEvent: 8491 free pages of 16 KB (~139 MB)
    /// and 571985 compressor pages (~9.4 GB), with the kernel screaming.
    static let jetsamSystem = system(
        freeBytes: 8491 * pageSize,
        compressedBytes: 571_985 * pageSize,
        available: 0.03
    )

    /// The machine's *ordinary* idle state, taken from a real 1260-sample log.
    ///
    /// This is the fixture that matters most: free memory sits at 0.8% and the compressor
    /// at ~39% during entirely healthy operation. Any rule that calls this dangerous will
    /// fire constantly and train the user to ignore the app.
    static let ordinaryBusySystem = system(
        freeBytes: 103_792_640,
        compressedBytes: 10_039_394_304,
        available: 0.46
    )

    /// The evening of 2026-08-22, minutes before a WindowServer watchdog kernel panic.
    ///
    /// Faithful to the panic report, which states `"memoryPressure": false`,
    /// `pagesWanted: 0`, `pagesReclaimed: 0`. The kernel saw **no** memory problem, and
    /// `wdavdaemon` was a harmless 55.69 MB. Every memory-derived signal this app has is
    /// green here — which is precisely why the stall probe exists.
    static let prePanicSystem = system(
        freeBytes: 6347 * pageSize,
        compressedBytes: 590_949 * pageSize,
        available: 0.46
    )

    /// A machine the kernel itself has flagged, as in the morning jetsam event.
    static let pressuredSystem = system(
        freeBytes: 8491 * pageSize,
        compressedBytes: 571_985 * pageSize,
        available: 0.03
    )

    /// Filesystem latency measured on a healthy machine with Defender's ES extension
    /// active: median 8.5 µs over 2000 iterations.
    static let healthyStall = StallReading(
        medianSeconds: 0.0000085, worstSeconds: 0.0000199, sampleCount: 25)

    /// What an Endpoint Security stall looks like: opens blocking for seconds.
    static let stalledFilesystem = StallReading(
        medianSeconds: 1.8, worstSeconds: 4.2, sampleCount: 25)

    static func sample(
        bytes: UInt64?,
        system: SystemMemoryUsage = healthySystem,
        stall: StallReading? = nil,
        at seconds: TimeInterval = 0
    ) -> MemorySample {
        MemorySample(
            timestamp: Date(timeIntervalSince1970: seconds),
            process: bytes.map { ProcessMemoryUsage(residentBytes: $0, processCount: 1, pids: [557]) },
            system: system,
            stall: stall
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

    func testOrdinaryOperationLooksIdenticalToTheJetsamStateByRawPageCounts() {
        // The whole reason severity moved to the kernel's pressure level: by raw page
        // counts a perfectly healthy machine is indistinguishable from one about to die.
        let ordinary = Fixture.ordinaryBusySystem
        XCTAssertLessThan(ordinary.freeFraction, 0.05)
        XCTAssertGreaterThan(ordinary.compressedFraction, 0.30)
        XCTAssertLessThan(Fixture.jetsamSystem.freeFraction, 0.05)
        XCTAssertGreaterThan(Fixture.jetsamSystem.compressedFraction, 0.30)
        // Same verdict from the old heuristic, opposite realities.
        XCTAssertNotEqual(ordinary.pressureLevel, Fixture.jetsamSystem.pressureLevel)
    }
}
