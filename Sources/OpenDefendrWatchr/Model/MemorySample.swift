import Foundation

/// Resident memory of the watched process, aggregated across every matching PID.
///
/// Defender ships several sibling executables (`wdavdaemon_enterprise`,
/// `wdavdaemon_unprivileged`, …). Only processes whose executable file name matches
/// exactly are counted here, so `wdavdaemon` numbers stay comparable with the
/// JetsamEvent report that motivated this app.
public struct ProcessMemoryUsage: Sendable, Equatable {
    public let residentBytes: UInt64
    public let processCount: Int
    public let pids: [Int32]

    public init(residentBytes: UInt64, processCount: Int, pids: [Int32] = []) {
        self.residentBytes = residentBytes
        self.processCount = processCount
        self.pids = pids
    }
}

/// System-wide memory state, derived from `host_statistics64` + `hw.memsize`.
public struct SystemMemoryUsage: Sendable, Equatable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let compressedBytes: UInt64
    /// Kernel page size in bytes. 16384 on Apple silicon, 4096 on Intel — never hardcode it.
    public let pageSize: UInt64

    public init(totalBytes: UInt64, freeBytes: UInt64, compressedBytes: UInt64, pageSize: UInt64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.compressedBytes = compressedBytes
        self.pageSize = pageSize
    }

    /// Fraction of physical RAM currently free (0...1). Returns 1 when total is unknown.
    public var freeFraction: Double {
        guard totalBytes > 0 else { return 1 }
        return Double(freeBytes) / Double(totalBytes)
    }

    /// Fraction of physical RAM held by the compressor (0...1).
    public var compressedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(compressedBytes) / Double(totalBytes)
    }
}

/// One poll tick: the watched process (nil when Defender is not running) plus system state.
public struct MemorySample: Sendable, Equatable {
    public let timestamp: Date
    public let process: ProcessMemoryUsage?
    public let system: SystemMemoryUsage

    public init(timestamp: Date, process: ProcessMemoryUsage?, system: SystemMemoryUsage) {
        self.timestamp = timestamp
        self.process = process
        self.system = system
    }

    /// Resident bytes of the watched process; 0 when it is not running.
    public var processResidentBytes: UInt64 { process?.residentBytes ?? 0 }

    public var isProcessRunning: Bool { process != nil }
}
