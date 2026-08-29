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

/// Swap file usage from `vm.swapusage`. Recorded as context only.
///
/// A nearly full swap file is *not* by itself a fault: macOS grows and reuses swap freely,
/// and 97% used has been observed on this machine with 35% of memory available. It earns a
/// column because it is the kind of signal one wants to correlate after the fact, not
/// because it is actionable on its own.
public struct SwapUsage: Sendable, Equatable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64

    public init(totalBytes: UInt64, usedBytes: UInt64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
    }

    /// `nil` rather than `0` when no swap file exists, so an absent swap file is not
    /// reported as an empty one.
    public var usedFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes)
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
    /// `vm.swapusage`. `nil` when unreadable — recorded as context, never used for alarm:
    /// a full swap file is normal on a machine that has simply been up a long time.
    public let swap: SwapUsage?

    public init(
        totalBytes: UInt64,
        freeBytes: UInt64,
        compressedBytes: UInt64,
        pageSize: UInt64,
        availableFraction: Double? = nil,
        kernelPressureLevel: MemoryPressureLevel = .normal,
        swap: SwapUsage? = nil
    ) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.compressedBytes = compressedBytes
        self.pageSize = pageSize
        self.availableFraction = availableFraction
        self.kernelPressureLevel = kernelPressureLevel
        self.swap = swap
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

/// What the process reader was able to determine this tick.
///
/// Three outcomes, deliberately kept distinct. Reading the watched process needs `ps`,
/// because `proc_pid_rusage` returns EPERM for a root-owned daemon and `ps` is setuid
/// root; so the one measurement in this app that requires a fork is also the first thing
/// to fail when the process table is exhausted. That happened for four hours on 28 August,
/// and collapsing `unreadable` into `notRunning` would have reported Defender as absent
/// while it was in fact unobservable.
public enum ProcessReadout: Sendable, Equatable {
    case running(ProcessMemoryUsage)
    /// Defender genuinely is not running. Never rendered as `0 B`.
    case notRunning
    /// The measurement could not be taken. Not a healthy reading, and not an absent process.
    case unreadable(reason: String)
}

/// One poll tick: the watched process (nil when Defender is not running) plus system state.
public struct MemorySample: Sendable, Equatable {
    public let timestamp: Date
    public let readout: ProcessReadout
    public let system: SystemMemoryUsage
    /// Filesystem responsiveness, or `nil` when the probe could not run. Memory is not the
    /// only way this machine dies: a stalled Endpoint Security client blocks threads
    /// system-wide while memory looks entirely healthy.
    public let stall: StallReading?

    public init(
        timestamp: Date,
        readout: ProcessReadout,
        system: SystemMemoryUsage,
        stall: StallReading? = nil
    ) {
        self.timestamp = timestamp
        self.readout = readout
        self.system = system
        self.stall = stall
    }

    public init(
        timestamp: Date,
        process: ProcessMemoryUsage?,
        system: SystemMemoryUsage,
        stall: StallReading? = nil
    ) {
        self.init(
            timestamp: timestamp,
            readout: process.map(ProcessReadout.running) ?? .notRunning,
            system: system,
            stall: stall)
    }

    public var process: ProcessMemoryUsage? {
        if case .running(let usage) = readout { return usage }
        return nil
    }

    /// Resident bytes of the watched process; 0 when it is not running.
    public var processResidentBytes: UInt64 { process?.residentBytes ?? 0 }

    public var isProcessRunning: Bool { process != nil }

    /// False when the reading could not be taken at all. Callers that would otherwise
    /// present "not running" must check this first: an unobservable process is not an
    /// absent one, and saying so would be the same fabrication as reporting `0 B`.
    public var isProcessReadable: Bool {
        if case .unreadable = readout { return false }
        return true
    }

    public var processUnreadableReason: String? {
        if case .unreadable(let reason) = readout { return reason }
        return nil
    }
}
