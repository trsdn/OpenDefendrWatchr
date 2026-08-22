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

/// The kernel's own memory pressure verdict.
///
/// Raw free pages are *not* a danger signal on macOS: the VM subsystem deliberately keeps
/// the free list nearly empty, so `free < 5%` held in 99.3% of the samples in a real
/// 1260-sample log taken during entirely normal operation.
///
/// `kern.memorystatus_vm_pressure_level` is not usable either, despite being the obvious
/// candidate. It is a *notification dispatch* level and latches: measured on a healthy
/// machine it reported `warning` continuously for minutes while `kern.memorystatus_level`
/// simultaneously reported 46% memory available. Trusting it would put the app in a
/// permanent warning state, which trains the user to ignore it — the same
/// constant-masquerading-as-a-signal mistake as the free-page rule.
///
/// So this level is derived from `kern.memorystatus_level`, the quantitative percentage
/// jetsam itself acts on. See `SystemMemoryUsage.pressureLevel`.
public enum MemoryPressureLevel: Int, Sendable, Equatable, Comparable, CaseIterable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Maps the raw sysctl value. Unknown values are treated as `.normal` rather than
    /// invented danger — a misread must not manufacture alerts.
    public init(rawKernelValue: Int32) {
        self = MemoryPressureLevel(rawValue: Int(rawKernelValue)) ?? .normal
    }

    public var title: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

/// System-wide memory state, derived from `host_statistics64` + `hw.memsize`.
public struct SystemMemoryUsage: Sendable, Equatable {
    /// At or below this fraction available, the machine is in trouble.
    public static let criticalAvailableFraction = 0.10
    /// At or below this fraction available, it is worth telling the user.
    public static let warningAvailableFraction = 0.20

    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let compressedBytes: UInt64
    /// Kernel page size in bytes. 16384 on Apple silicon, 4096 on Intel — never hardcode it.
    public let pageSize: UInt64
    /// `kern.memorystatus_level / 100` — the share of memory jetsam considers available.
    /// `nil` when the sysctl could not be read; that is "unknown", never "fine".
    public let availableFraction: Double?
    /// Raw `kern.memorystatus_vm_pressure_level`, recorded for the incident log only.
    /// Deliberately not used for alarm — see `MemoryPressureLevel` for why it latches.
    public let kernelPressureLevel: MemoryPressureLevel

    public init(
        totalBytes: UInt64,
        freeBytes: UInt64,
        compressedBytes: UInt64,
        pageSize: UInt64,
        availableFraction: Double? = nil,
        kernelPressureLevel: MemoryPressureLevel = .normal
    ) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.compressedBytes = compressedBytes
        self.pageSize = pageSize
        self.availableFraction = availableFraction
        self.kernelPressureLevel = kernelPressureLevel
    }

    /// The verdict severity is derived from. An unreadable measurement yields `.normal`:
    /// a failed sysctl must not manufacture an alert.
    public var pressureLevel: MemoryPressureLevel {
        guard let availableFraction else { return .normal }
        if availableFraction <= Self.criticalAvailableFraction { return .critical }
        if availableFraction <= Self.warningAvailableFraction { return .warning }
        return .normal
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
    /// Filesystem responsiveness, or `nil` when the probe could not run. Memory is not the
    /// only way this machine dies: a stalled Endpoint Security client blocks threads
    /// system-wide while memory looks entirely healthy.
    public let stall: StallReading?

    public init(
        timestamp: Date,
        process: ProcessMemoryUsage?,
        system: SystemMemoryUsage,
        stall: StallReading? = nil
    ) {
        self.timestamp = timestamp
        self.process = process
        self.system = system
        self.stall = stall
    }

    /// Resident bytes of the watched process; 0 when it is not running.
    public var processResidentBytes: UInt64 { process?.residentBytes ?? 0 }

    public var isProcessRunning: Bool { process != nil }
}
