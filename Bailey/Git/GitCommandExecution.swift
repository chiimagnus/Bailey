import Foundation

nonisolated enum GitCommandExecution {
    private static let localEnvironment = loadLoginEnvironment()

    private static let gitErrorBytes = 64 * 1024
    private static let outputExceededMessage = String(
        localized: "Git output exceeded the allowed size.", table: "Git"
    )

    static func loadLoginEnvironment(
        shell: String = LocalWorkspaceBackend.loginShell,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5
    ) -> (status: Int32, values: [String: String], stderr: String) {
        let marker = "\0bailey-git-\(UUID().uuidString)\0"
        let result = runProcess(
            ["-ilc", "/usr/bin/printf '\\0\(marker.dropFirst().dropLast())\\0'; exec /usr/bin/env -0"],
            executable: shell, in: NSHomeDirectory(), environment: environment,
            timeout: timeout, stdoutLimit: 1024 * 1024 + 1,
            honorTaskCancellation: false
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

    /// Executes Git via the shared bounded, cancellable local process reader.
    /// A single polling owner drains both streams without blocking separate threads.
    static func runData(
        _ args: [String], in dir: String, timeout: TimeInterval? = nil,
        stdoutLimit: Int? = nil, stdin: Data? = nil
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
            environment: env, timeout: remaining, stdoutLimit: stdoutLimit, stdin: stdin
        )
    }

    private static func runProcess(
        _ args: [String], executable: String, in dir: String,
        environment: [String: String], timeout: TimeInterval?, stdoutLimit: Int?,
        stdin: Data? = nil, honorTaskCancellation: Bool = true
    ) -> (status: Int32, stdout: Data, stderr: String) {
        // Use the same cancellable, bounded FD-polling process owner as local
        // workspace commands. The former Git-only reader threads could stay
        // blocked after cancellation when a descendant inherited a pipe.
        do {
            let result = try LocalWorkspaceBackend.runSync(
                argv: [executable] + args, cwd: dir, env: environment,
                stdin: stdin, timeout: timeout, stdoutLimit: stdoutLimit,
                stderrLimit: stdoutLimit == nil ? nil : gitErrorBytes,
                preservePartialOnTimeout: true,
                honorTaskCancellation: honorTaskCancellation
            )
            let detail = String(decoding: result.stderr, as: UTF8.self)
            if result.status == -2 {
                return (-2, result.stdout, detail + "\n" + String(
                    localized: "Git did not respond in time.", table: "Git"
                ))
            }
            return (result.status, result.stdout, detail)
        } catch is CancellationError {
            return (-4, Data(), String(localized: "Git command was cancelled.", table: "Git"))
        } catch WorkspaceError.tooLarge {
            return (-3, Data(), outputExceededMessage)
        } catch WorkspaceError.timedOut {
            return (-2, Data(), String(localized: "Git did not respond in time.", table: "Git"))
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
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
        stdoutLimit: Int? = nil, stdin: Data? = nil, backend: WorkspaceBackend
    ) async -> (status: Int32, stdout: Data, stderr: String) {
        precondition(stdoutLimit == nil || stdoutLimit! >= 0)
        if Task.isCancelled {
            return (-4, Data(), String(localized: "Git command was cancelled.", table: "Git"))
        }
        if backend is LocalWorkspaceBackend {
            return runData(args, in: dir, timeout: timeout,
                           stdoutLimit: stdoutLimit, stdin: stdin)
        }
        do {
            let argv = ["git"] + args
            let env = ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
            let result: WorkspaceRunResult
            if let stdoutLimit {
                result = try await backend.runLimited(
                    argv: argv, cwd: dir, env: env, stdin: stdin, timeout: timeout,
                    stdoutLimit: stdoutLimit, stderrLimit: gitErrorBytes
                )
            } else {
                result = try await backend.run(
                    argv: argv, cwd: dir, env: env, stdin: stdin, timeout: timeout
                )
            }
            return (result.status, result.stdout, String(data: result.stderr, encoding: .utf8) ?? "")
        } catch WorkspaceError.tooLarge {
            return (-3, Data(), outputExceededMessage)
        } catch WorkspaceError.timedOut {
            return (-2, Data(), String(localized: "Git did not respond in time.", table: "Git"))
        } catch is CancellationError {
            return (-4, Data(), String(localized: "Git command was cancelled.", table: "Git"))
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
    }
}
