import Darwin
import Foundation

nonisolated enum GitCommandExecution {
    private static let localEnvironment = loadLoginEnvironment()

    private final class PipeData: @unchecked Sendable {
        var value = Data()
    }

    static func loadLoginEnvironment(
        shell: String = LocalWorkspaceBackend.loginShell,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5
    ) -> (status: Int32, values: [String: String], stderr: String) {
        let marker = "\0bailey-git-\(UUID().uuidString)\0"
        let result = runProcess(
            ["-ilc", "/usr/bin/printf '\\0\(marker.dropFirst().dropLast())\\0'; exec /usr/bin/env -0"],
            executable: shell, in: NSHomeDirectory(), environment: environment,
            timeout: timeout, stdoutLimit: 1024 * 1024 + 1
        )
        let error = String(localized: "Could not load the login shell environment. Check your shell startup files and restart Bailey.", table: "Git")
        guard result.status == 0,
              result.stdout.count <= 1024 * 1024,
              let range = result.stdout.range(of: Data(marker.utf8)),
              result.stdout.last == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return (result.status == 0 ? -1 : result.status, [:], detail.isEmpty ? error : error + "\n" + detail)
        }
        var values: [String: String] = [:]
        for entry in result.stdout[range.upperBound...].split(separator: 0) {
            let parts = String(decoding: entry, as: UTF8.self).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return (-1, [:], error) }
            values[String(parts[0])] = String(parts[1])
        }
        guard let path = values["PATH"], !path.isEmpty else { return (-1, [:], error) }
        return (0, values, "")
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
        let started = ProcessInfo.processInfo.systemUptime
        let resolved = localEnvironment
        guard resolved.status == 0 else { return (resolved.status, Data(), resolved.stderr) }
        let remaining = timeout.map { $0 - (ProcessInfo.processInfo.systemUptime - started) }
        if let remaining, remaining <= 0 {
            return (-2, Data(), String(localized: "Git did not respond in time.", table: "Git"))
        }
        var env = resolved.values
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        return runProcess(
            ["git"] + args, executable: "/usr/bin/env", in: dir,
            environment: env, timeout: remaining, stdoutLimit: stdoutLimit
        )
    }

    private static func runProcess(
        _ args: [String], executable: String, in dir: String,
        environment: [String: String], timeout: TimeInterval?, stdoutLimit: Int?
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        process.environment = environment

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
            let deadline = DispatchTime.now() + timeout
            var processStillRunning = processExited.wait(timeout: deadline) == .timedOut
            let pipesStillOpen = readers.wait(timeout: deadline) == .timedOut
            timedOut = processStillRunning || pipesStillOpen
            if timedOut {
                if processStillRunning, process.isRunning { process.terminate() }
                let terminationDeadline = DispatchTime.now() + 1
                processStillRunning = processStillRunning
                    && processExited.wait(timeout: terminationDeadline) == .timedOut
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
