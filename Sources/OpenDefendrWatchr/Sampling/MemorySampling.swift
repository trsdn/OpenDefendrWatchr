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
    private let executableName: String
    private let clock: @Sendable () -> Date

    public init(
        processReader: ProcessMemoryReading = CompositeProcessMemoryReader(),
        systemReader: SystemMemoryReading = HostSystemMemoryReader(),
        executableName: String = DefenderMemorySampler.defaultExecutableName,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processReader = processReader
        self.systemReader = systemReader
        self.executableName = executableName
        self.clock = clock
    }

    public func sample() throws -> MemorySample {
        let system = try systemReader.read()
        let process = try processReader.usage(forExecutableNamed: executableName)
        return MemorySample(timestamp: clock(), process: process, system: system)
    }
}
