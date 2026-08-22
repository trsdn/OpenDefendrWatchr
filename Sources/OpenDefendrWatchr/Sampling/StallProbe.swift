import Foundation

/// How long trivial filesystem work is currently taking.
///
/// Every `open()` on this machine is routed through the kernel's Endpoint Security layer
/// and authorised by whatever ES clients are installed (here: Microsoft Defender's
/// `com.microsoft.wdav.epsext`). When such a client stops answering promptly, the calling
/// thread blocks *in the kernel* — so the latency of an otherwise free operation becomes a
/// direct measurement of that stall.
public struct StallReading: Sendable, Equatable {
    /// Median duration of one probe operation. The median, not the mean, because a single
    /// descheduled sample would otherwise dominate a short run.
    public let medianSeconds: Double
    public let worstSeconds: Double
    public let sampleCount: Int

    public init(medianSeconds: Double, worstSeconds: Double, sampleCount: Int) {
        self.medianSeconds = medianSeconds
        self.worstSeconds = worstSeconds
        self.sampleCount = sampleCount
    }

    public var medianMicroseconds: Double { medianSeconds * 1_000_000 }
}

/// Anything that can measure how responsive the filesystem path is. Injected so tests can
/// simulate a stall without needing to actually wedge Endpoint Security.
public protocol SystemStallProbing: Sendable {
    /// Returns `nil` when no measurement could be taken. A failed probe must not be
    /// reported as a fast one — absence of data is not evidence of health.
    func measure() -> StallReading?
}

/// Times repeated `open()`/`close()` cycles on a small file this app owns.
///
/// The file is deliberately tiny and reused, so it stays in the page cache and the only
/// meaningful variable left in the measurement is kernel-side authorisation latency.
public struct FileOpenStallProbe: SystemStallProbing {
    private let fileURL: URL
    private let iterations: Int

    public init(
        directory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        iterations: Int = 25
    ) {
        self.fileURL = directory.appendingPathComponent("com.opendefendrwatchr.stallprobe")
        self.iterations = max(3, iterations)
    }

    public func measure() -> StallReading? {
        guard ensureProbeFileExists() else { return nil }

        let path = fileURL.path
        var durations: [Double] = []
        durations.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let fd = path.withCString { open($0, O_RDONLY) }
            guard fd >= 0 else { return nil }
            close(fd)
            let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
            durations.append(Double(elapsed) / 1_000_000_000)
        }

        guard !durations.isEmpty else { return nil }
        durations.sort()
        return StallReading(
            medianSeconds: durations[durations.count / 2],
            worstSeconds: durations[durations.count - 1],
            sampleCount: durations.count
        )
    }

    private func ensureProbeFileExists() -> Bool {
        if FileManager.default.fileExists(atPath: fileURL.path) { return true }
        return FileManager.default.createFile(
            atPath: fileURL.path, contents: Data(repeating: 0, count: 64))
    }
}

/// Latency above which the machine is considered to be stalling.
///
/// Calibrated against a measured baseline on a healthy machine *with Defender's Endpoint
/// Security extension active and authorising every open*: median 8.5 µs, p99 16 µs, worst
/// 20 µs over 2000 iterations. The warning threshold therefore sits roughly three orders of
/// magnitude above normal, which is far outside anything ordinary scheduling jitter or disk
/// contention produces, and well below the multi-second blocking seen during a real stall.
public struct StallThresholds: Sendable, Equatable {
    public static let defaultWarningSeconds: Double = 0.025
    public static let defaultCriticalSeconds: Double = 0.250

    public var warningSeconds: Double
    public var criticalSeconds: Double

    public init(
        warningSeconds: Double = StallThresholds.defaultWarningSeconds,
        criticalSeconds: Double = StallThresholds.defaultCriticalSeconds
    ) {
        self.warningSeconds = warningSeconds
        // A critical threshold below the warning one would make warning unreachable.
        self.criticalSeconds = max(criticalSeconds, warningSeconds)
    }
}
