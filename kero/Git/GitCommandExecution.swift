import Darwin
import Foundation

nonisolated enum GitCommandExecution {
    private final class PipeData: @unchecked Sendable {
        var value = Data()
    }

    /// Runs Git while draining stdout and stderr concurrently. Dedicated
    /// reader threads are intentional: several restored diff tabs can call
    /// this from Swift's cooperative executor at once, and dispatching the
    /// readers back onto the shared pool can starve every pipe drain.
    static func runData(
        _ args: [String], in dir: String, timeout: TimeInterval? = nil,
        stdoutLimit: Int? = nil
    ) -> (status: Int32, stdout: Data, stderr: String) {
        precondition(stdoutLimit == nil || stdoutLimit! >= 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Fail rather than hanging on a credential prompt behind the app.
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Git diagnostics are parsed only to distinguish an ordinary folder
        // from a broken repository. Pinning the locale makes that safe and
        // also keeps relative dates stable in the compact history list.
        env["LC_ALL"] = "C"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let processExited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processExited.signal() }

        do {
            try process.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
        let ownsProcessGroup = getpgid(process.processIdentifier) == process.processIdentifier
        let outData = PipeData()
        let errData = PipeData()
        let readers = DispatchGroup()
        // These readers are on the synchronous completion path below. Match
        // the caller so a user-initiated Git request never waits on utility
        // threads, while background refreshes keep their lower priority.
        let readerQualityOfService = Thread.current.qualityOfService
        readers.enter()
        let stdoutReader = Thread {
            while true {
                let chunk: Data
                do {
                    guard let next = try stdout.fileHandleForReading.read(upToCount: 64 * 1024),
                          !next.isEmpty else { break }
                    chunk = next
                } catch {
                    break
                }
                let remaining = (stdoutLimit ?? .max) - outData.value.count
                if remaining > 0 {
                    outData.value.append(chunk.prefix(remaining))
                }
            }
            readers.leave()
        }
        stdoutReader.qualityOfService = readerQualityOfService
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        stderrReader.qualityOfService = readerQualityOfService
        stderrReader.start()
        var timedOut = false
        if let timeout {
            timedOut = processExited.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                let terminationDeadline = DispatchTime.now() + 1
                let processStillRunning = processExited.wait(timeout: terminationDeadline) == .timedOut
                let pipesStillOpen = readers.wait(timeout: terminationDeadline) == .timedOut
                if processStillRunning || pipesStillOpen, ownsProcessGroup {
                    Darwin.kill(-process.processIdentifier, SIGKILL)
                } else if processStillRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
        } else {
            process.waitUntilExit()
        }
        readers.wait()
        let output = outData.value
        var errorOutput = String(data: errData.value, encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = String(localized: "Git did not respond in time.", table: "Git")
            if !errorOutput.isEmpty, !errorOutput.hasSuffix("\n") {
                errorOutput += "\n"
            }
            errorOutput += timeoutMessage
            return (-2, output, errorOutput)
        }
        return (
            process.terminationStatus,
            output,
            errorOutput
        )
    }

    static func run(
        _ args: [String], in dir: String, timeout: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String) {
        let result = runData(args, in: dir, timeout: timeout)
        return (result.status, String(data: result.stdout, encoding: .utf8) ?? "", result.stderr)
    }

    @concurrent static func run(
        _ args: [String], in dir: String, timeout: TimeInterval? = nil,
        backend: WorkspaceBackend
    ) async -> (status: Int32, stdout: String, stderr: String) {
        let result = await runData(args, in: dir, timeout: timeout, backend: backend)
        return (result.status, String(data: result.stdout, encoding: .utf8) ?? "", result.stderr)
    }

    @concurrent static func runData(
        _ args: [String], in dir: String, timeout: TimeInterval? = nil,
        stdoutLimit: Int? = nil, backend: WorkspaceBackend
    ) async -> (status: Int32, stdout: Data, stderr: String) {
        precondition(stdoutLimit == nil || stdoutLimit! >= 0)
        if backend is LocalWorkspaceBackend {
            return runData(args, in: dir, timeout: timeout, stdoutLimit: stdoutLimit)
        }
        do {
            let result = try await backend.run(
                argv: ["git"] + args, cwd: dir,
                env: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
                stdin: nil, timeout: timeout
            )
            let output = stdoutLimit.map { Data(result.stdout.prefix($0)) } ?? result.stdout
            return (result.status, output, String(data: result.stderr, encoding: .utf8) ?? "")
        } catch WorkspaceError.timedOut {
            return (-2, Data(), String(localized: "Git did not respond in time.", table: "Git"))
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
    }
}
