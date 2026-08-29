import Foundation

/// Result of running an external command: everything the user needs to see, including
/// the parts we would otherwise be tempted to swallow.
public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

/// A subprocess that could not be started.
///
/// `EAGAIN` is singled out because it is not a failure of the command: it means the kernel
/// refused to create *any* new process. Measured on this machine, 796 spawn failures across
/// four unrelated applications preceded a reboot by four hours, so this condition is worth
/// naming precisely rather than folding into a generic error string.
public enum CommandSpawnError: Error, Equatable {
    case resourceUnavailable(executable: String)

    public static func isResourceUnavailable(_ error: Error) -> Bool {
        if case .resourceUnavailable = error as? CommandSpawnError { return true }
        return false
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            // Foundation surfaces a spawn refusal as POSIX EAGAIN. Translating it here
            // keeps the "why" attached to the failure instead of leaving callers to guess
            // from a stringified NSError.
            let nsError = error as NSError
            let isEAGAIN =
                (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EAGAIN))
                || (nsError.underlyingErrors.contains {
                    let underlying = $0 as NSError
                    return underlying.domain == NSPOSIXErrorDomain
                        && underlying.code == Int(EAGAIN)
                })
            if isEAGAIN { throw CommandSpawnError.resourceUnavailable(executable: executable) }
            throw error
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }
}
