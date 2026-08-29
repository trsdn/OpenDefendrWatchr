import Foundation

/// Anything that can produce one memory sample. Injected so the UI, monitor and tests
/// never depend on a live `wdavdaemon`.
public protocol MemorySampling: Sendable {
    func sample() throws -> MemorySample
}

/// Reads resident memory for all processes whose executable file name matches exactly.
public protocol ProcessMemoryReading: Sendable {
    /// Returns `nil` when no matching process exists (Defender not installed / not running).
    func usage(forExecutableNamed name: String) throws -> ProcessMemoryUsage?
}

/// Reads system-wide memory state.
public protocol SystemMemoryReading: Sendable {
    func read() throws -> SystemMemoryUsage
}

/// Combines a process reader and a system reader into a single tick.
public struct DefenderMemorySampler: MemorySampling {
    /// Microsoft Defender's main daemon. Deliberately *not* `wdavdaemon_enterprise` or
    /// `wdavdaemon_unprivileged` — the runaway process in the incident was this one.
    public static let defaultExecutableName = "wdavdaemon"

    private let processReader: ProcessMemoryReading
    private let systemReader: SystemMemoryReading
    private let stallProbe: SystemStallProbing
    private let executableName: String
    private let clock: @Sendable () -> Date

    public init(
        processReader: ProcessMemoryReading = CompositeProcessMemoryReader(),
        systemReader: SystemMemoryReading = HostSystemMemoryReader(),
        stallProbe: SystemStallProbing = FileOpenStallProbe(),
        executableName: String = DefenderMemorySampler.defaultExecutableName,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processReader = processReader
        self.systemReader = systemReader
        self.stallProbe = stallProbe
        self.executableName = executableName
        self.clock = clock
    }

    public func sample() throws -> MemorySample {
        // Probed first, before the heavier readers below have a chance to warm caches or
        // perturb the very latency being measured.
        let stall = stallProbe.measure()
        let system = try systemReader.read()

        // Only the process reading needs a subprocess, and it is therefore the only part
        // that fails when the process table is exhausted. Losing it must not discard the
        // system and stall readings, which were already taken and need no fork — those are
        // precisely the signals that matter while the machine is running out of resources.
        // On 28 August this threw for four hours and took the whole tick with it, leaving
        // no rows at all in the log for the period of greatest interest.
        let readout: ProcessReadout
        do {
            readout = try processReader.usage(forExecutableNamed: executableName)
                .map(ProcessReadout.running) ?? .notRunning
        } catch {
            readout = .unreadable(reason: SamplingFailure.describe(error))
        }

        return MemorySample(
            timestamp: clock(), readout: readout, system: system, stall: stall)
    }
}

/// Turns a reader error into wording a user can act on.
public enum SamplingFailure {
    /// `EAGAIN` from a spawn means the system could not create another process. That is a
    /// machine-wide condition, not a quirk of this app, so it is named as such rather than
    /// reported as a generic failure to read Defender.
    public static func describe(_ error: Error) -> String {
        if CommandSpawnError.isResourceUnavailable(error) {
            return "process table exhausted (EAGAIN)"
        }
        return String(describing: error)
    }
}
