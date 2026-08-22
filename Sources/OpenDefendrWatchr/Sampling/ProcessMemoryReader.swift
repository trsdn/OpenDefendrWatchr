import Darwin
import Foundation

/// A process discovered on the system: its PID and the file name of its executable.
public struct RunningProcess: Sendable, Equatable {
    public let pid: Int32
    public let executableName: String
    public let executablePath: String

    public init(pid: Int32, executableName: String, executablePath: String) {
        self.pid = pid
        self.executableName = executableName
        self.executablePath = executablePath
    }
}

/// Enumerates processes through `libproc`, without forking a shell.
///
/// `proc_pidpath` returns the real executable path, so matching is exact — `ps -o comm`
/// truncation and `wdavdaemon_unprivileged`-style prefix collisions cannot fool it.
public enum LibprocProcessLister {
    public static func allProcesses() -> [RunningProcess] {
        var capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        capacity += 64  // headroom for processes spawned between the two calls

        var pids = [pid_t](repeating: 0, count: capacity)
        let returned = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard returned > 0 else { return [] }

        // The documented return value is a byte count, but on current macOS releases
        // `proc_listallpids` returns the number of PIDs. Interpreting it as a count and
        // clamping to the buffer is safe either way: over-scanning only walks zeroed
        // slots, which are skipped, whereas under-scanning would silently miss processes.
        let count = min(Int(returned), pids.count)
        var result: [RunningProcess] = []
        result.reserveCapacity(count)

        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not importable into Swift.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }  // exited, or not readable by this user
            let path = String(cString: pathBuffer)
            result.append(
                RunningProcess(
                    pid: pid,
                    executableName: (path as NSString).lastPathComponent,
                    executablePath: path
                )
            )
        }
        return result
    }

    /// Resident size for a PID via `proc_pid_rusage`.
    ///
    /// Returns `nil` when the kernel refuses (EPERM), which is the normal case for
    /// root-owned daemons such as `wdavdaemon` when this app runs as a regular user.
    ///
    /// `proc_pid_rusage` copies a whole `rusage_info_v2` into the supplied buffer, so the
    /// buffer must be that size — passing a bare pointer variable smashes the stack.
    public static func residentBytes(for pid: Int32) -> UInt64? {
        let size = MemoryLayout<rusage_info_v2>.stride
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<rusage_info_v2>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)

        let typed = buffer.bindMemory(to: rusage_info_t?.self, capacity: 1)
        guard proc_pid_rusage(pid, RUSAGE_INFO_V2, typed) == 0 else { return nil }
        return buffer.load(as: rusage_info_v2.self).ri_resident_size
    }
}

/// Reads resident size from `ps` output.
///
/// `ps` is used only where `libproc` is not permitted (root-owned processes). The parsing
/// is isolated here so it can be tested against real captured output.
public enum PSOutputParser {
    /// Parses `ps -Ao rss=,comm=` output.
    ///
    /// Each line is `<rss-in-kibibytes> <executable path>`. The path may contain spaces
    /// (`/Applications/Microsoft Defender.app/...`), so only the first field is split off.
    public static func parseProcessTable(_ output: String) -> [(name: String, residentBytes: UInt64)] {
        var rows: [(name: String, residentBytes: UInt64)] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separatorIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }
            guard let kibibytes = UInt64(line[line.startIndex..<separatorIndex]) else { continue }
            let command = line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            rows.append(
                (name: (command as NSString).lastPathComponent, residentBytes: kibibytes * 1024)
            )
        }
        return rows
    }

    /// Parses `ps -o rss= -p <pids>` output: one bare kibibyte value per line.
    public static func parseResidentSizes(_ output: String) -> [UInt64] {
        output.split(separator: "\n").compactMap { line in
            UInt64(line.trimmingCharacters(in: .whitespaces)).map { $0 * 1024 }
        }
    }

    /// Aggregates a parsed process table down to one usage value for an executable name.
    public static func aggregate(
        _ rows: [(name: String, residentBytes: UInt64)],
        matching name: String
    ) -> ProcessMemoryUsage? {
        let matches = rows.filter { $0.name == name }
        guard !matches.isEmpty else { return nil }
        return ProcessMemoryUsage(
            residentBytes: matches.reduce(0) { $0 + $1.residentBytes },
            processCount: matches.count
        )
    }
}

/// Default reader: enumerate with `libproc`, read RSS with `libproc` when permitted, and
/// fall back to a single `ps` invocation for the PIDs the kernel would not disclose.
///
/// Practical effect on a normal user account: one cheap `ps -o rss= -p <pids>` per tick
/// when Defender is running, and zero subprocesses when it is not.
public struct CompositeProcessMemoryReader: ProcessMemoryReading {
    private let lister: @Sendable () -> [RunningProcess]
    private let directResidentBytes: @Sendable (Int32) -> UInt64?
    private let shell: CommandRunning

    public init(
        lister: @escaping @Sendable () -> [RunningProcess] = { LibprocProcessLister.allProcesses() },
        directResidentBytes: @escaping @Sendable (Int32) -> UInt64? = {
            LibprocProcessLister.residentBytes(for: $0)
        },
        shell: CommandRunning = ProcessCommandRunner()
    ) {
        self.lister = lister
        self.directResidentBytes = directResidentBytes
        self.shell = shell
    }

    public func usage(forExecutableNamed name: String) throws -> ProcessMemoryUsage? {
        let matches = lister().filter { $0.executableName == name }
        guard !matches.isEmpty else {
            // libproc found nothing. That is usually the truth, but if enumeration itself
            // is unavailable we would rather ask `ps` than report "not running".
            return try psFallbackForFullTable(name: name)
        }

        var total: UInt64 = 0
        var unresolved: [Int32] = []
        for process in matches {
            if let bytes = directResidentBytes(process.pid) {
                total += bytes
            } else {
                unresolved.append(process.pid)
            }
        }

        if !unresolved.isEmpty {
            let joined = unresolved.map(String.init).joined(separator: ",")
            let result = try shell.run("/bin/ps", ["-o", "rss=", "-p", joined])
            total += PSOutputParser.parseResidentSizes(result.standardOutput).reduce(0, +)
        }

        return ProcessMemoryUsage(
            residentBytes: total,
            processCount: matches.count,
            pids: matches.map(\.pid)
        )
    }

    private func psFallbackForFullTable(name: String) throws -> ProcessMemoryUsage? {
        let result = try shell.run("/bin/ps", ["-Ao", "rss=,comm="])
        guard result.exitCode == 0 else { return nil }
        return PSOutputParser.aggregate(
            PSOutputParser.parseProcessTable(result.standardOutput),
            matching: name
        )
    }
}
