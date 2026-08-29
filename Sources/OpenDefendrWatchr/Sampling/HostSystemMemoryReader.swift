import Darwin
import Foundation

/// System memory via `host_statistics64(HOST_VM_INFO64)` and `sysctl hw.memsize`.
///
/// Page size is queried (`host_page_size`), never assumed: it is 16384 on Apple silicon
/// and 4096 on Intel, and every page count below has to be scaled by it.
public struct HostSystemMemoryReader: SystemMemoryReading {
    public init() {}

    public enum ReadError: Error, CustomStringConvertible {
        case hostStatisticsFailed(kern_return_t)
        case pageSizeUnavailable(kern_return_t)

        public var description: String {
            switch self {
            case .hostStatisticsFailed(let code): return "host_statistics64 failed (\(code))"
            case .pageSizeUnavailable(let code): return "host_page_size failed (\(code))"
            }
        }
    }

    public func read() throws -> SystemMemoryUsage {
        let host = mach_host_self()

        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS else { throw ReadError.pageSizeUnavailable(pageResult) }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw ReadError.hostStatisticsFailed(result) }

        let bytesPerPage = UInt64(pageSize)
        return SystemMemoryUsage(
            totalBytes: Self.physicalMemoryBytes(),
            freeBytes: UInt64(stats.free_count) * bytesPerPage,
            compressedBytes: UInt64(stats.compressor_page_count) * bytesPerPage,
            pageSize: bytesPerPage,
            availableFraction: Self.availableFraction(),
            kernelPressureLevel: Self.kernelPressureLevel(),
            swap: Self.swapUsage()
        )
    }

    /// `vm.swapusage`. Returns `nil` when the sysctl is unreadable, so "unknown" is never
    /// written to the log as "no swap in use".
    static func swapUsage() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(totalBytes: usage.xsu_total, usedBytes: usage.xsu_used)
    }

    /// `kern.memorystatus_level`, the percentage of memory jetsam considers available.
    /// Returns `nil` when unreadable so the caller can tell "unknown" from "healthy".
    static func availableFraction() -> Double? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0,
            (0...100).contains(value)
        else { return nil }
        return Double(value) / 100
    }

    /// The raw dispatch level, logged as context only. It latches at `warning` on a
    /// perfectly healthy machine, so it must not drive alarm.
    static func kernelPressureLevel() -> MemoryPressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0
        else { return .normal }
        return MemoryPressureLevel(rawKernelValue: value)
    }

    private static func physicalMemoryBytes() -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0, value > 0 {
            return value
        }
        return ProcessInfo.processInfo.physicalMemory
    }
}
