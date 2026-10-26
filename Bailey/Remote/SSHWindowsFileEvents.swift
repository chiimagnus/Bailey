import Darwin
import Foundation

/// A short-lived Windows watcher owned by a visible remote workspace.
/// It uses its own PTY session: the shared SSH master does not reap cancelled PowerShell children.
nonisolated enum SSHWindowsFileEvents {
    enum Event: Sendable, Equatable {
        case ready
        case dirty
        case lost
        case ended
    }

    static func parse(_ line: String, token: String) -> Event? {
        let prefix = "BAILEY:\(token):"
        guard let range = line.range(of: prefix) else { return nil }
        let marker = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        switch marker {
        case "READY": return .ready
        case "DIRTY": return .dirty
        case "LOST": return .lost
        case "END": return .ended
        default: return nil
        }
    }

    struct Subscription: Sendable {
        let events: AsyncStream<Event>
        let cancel: @Sendable () -> Void
    }

    static func subscribe(
        host: String, windowsRoot: String, leaseSeconds: Int = 60
    ) -> Subscription {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Event.self, bufferingPolicy: .bufferingNewest(8)
        )
        let token = UUID().uuidString
        let task = Task.detached(priority: .utility) {
            observe(
                host: host, windowsRoot: windowsRoot, token: token,
                leaseSeconds: leaseSeconds, continuation: continuation
            )
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return Subscription(events: stream, cancel: { task.cancel() })
    }

    private static func utf16Base64(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf16.count * 2)
        for codeUnit in text.utf16 {
            bytes.append(UInt8(truncatingIfNeeded: codeUnit))
            bytes.append(UInt8(truncatingIfNeeded: codeUnit >> 8))
        }
        return Data(bytes).base64EncodedString()
    }

    private static func script(root: String, token: String, leaseSeconds: Int) -> String {
        let encodedRoot = utf16Base64(root)
        return """
        $ErrorActionPreference='Stop'
        $root=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('\(encodedRoot)'))
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
        if($drive.DriveType -ne [IO.DriveType]::Fixed) {
          [Console]::WriteLine('BAILEY:\(token):LOST')
          [Console]::Out.Flush()
          return
        }
        $watch=[IO.FileSystemWatcher]::new($root)
        $watch.IncludeSubdirectories=$true
        $watch.NotifyFilter=[IO.NotifyFilters]'FileName,DirectoryName,LastWrite,CreationTime'
        $changed=[Threading.AutoResetEvent]::new($false)
        $lost=[Threading.AutoResetEvent]::new($false)
        $names=@('Created','Changed','Deleted','Renamed')
        try {
          foreach($name in $names) {
            Register-ObjectEvent -InputObject $watch -EventName $name -SourceIdentifier ('B-'+$name) -MessageData $changed -Action { [void]$event.MessageData.Set() } | Out-Null
          }
          Register-ObjectEvent -InputObject $watch -EventName Error -SourceIdentifier 'B-Error' -MessageData $lost -Action { [void]$event.MessageData.Set() } | Out-Null
          $watch.EnableRaisingEvents=$true
          [Console]::WriteLine('BAILEY:\(token):READY')
          [Console]::Out.Flush()
          $until=[DateTime]::UtcNow.AddSeconds(\(leaseSeconds))
          $next=[DateTime]::MinValue
          $pending=$false
          while([DateTime]::UtcNow -lt $until) {
            if($changed.WaitOne(200)) { $pending=$true }
            if(![IO.Directory]::Exists($root) -or $lost.WaitOne(0)) {
              [Console]::WriteLine('BAILEY:\(token):LOST')
              [Console]::Out.Flush()
              break
            }
            $now=[DateTime]::UtcNow
            if($pending -and $now -ge $next) {
              [Console]::WriteLine('BAILEY:\(token):DIRTY')
              [Console]::Out.Flush()
              $pending=$false
              $next=$now.AddMilliseconds(2000)
            }
          }
          [Console]::WriteLine('BAILEY:\(token):END')
          [Console]::Out.Flush()
        } finally {
          $watch.EnableRaisingEvents=$false
          foreach($name in ($names+@('Error'))) {
            Unregister-Event -SourceIdentifier ('B-'+$name) -ErrorAction SilentlyContinue
          }
          $watch.Dispose()
          $changed.Dispose()
          $lost.Dispose()
        }
        """
    }

    private static func observe(
        host: String, windowsRoot: String, token: String, leaseSeconds: Int,
        continuation: AsyncStream<Event>.Continuation
    ) {
        defer { continuation.finish() }
        guard !host.isEmpty, !host.hasPrefix("-"),
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !windowsRoot.isEmpty, (10...300).contains(leaseSeconds)
        else {
            continuation.yield(.lost)
            return
        }
        let command = "powershell.exe -NoProfile -NonInteractive -EncodedCommand "
            + utf16Base64(script(root: windowsRoot, token: token, leaseSeconds: leaseSeconds))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ControlMaster=no", "-S", "none",
            "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=3",
            "-o", "ServerAliveCountMax=2", "-tt", "--", host, command
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do { try process.run() }
        catch {
            continuation.yield(.lost)
            return
        }
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        for descriptor in [outFD, errFD] {
            let flags = fcntl(descriptor, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }
        var pending = [UInt8]()
        var sawEnd = false
        var sawReady = false
        let started = Date()
        var openDescriptors: Set<Int32> = [outFD, errFD]
        var buffer = [UInt8](repeating: 0, count: 4_096)
        // stdout carries the only trusted event frames. Its EOF invalidates
        // the stream even if a remote child still holds stderr open.
        while !Task<Never, Never>.isCancelled && openDescriptors.contains(outFD) && !sawEnd {
            if Date().timeIntervalSince(started) > Double(leaseSeconds + 20)
                || (!sawReady && Date().timeIntervalSince(started) > 15) { break }
            var fds = openDescriptors.sorted().map {
                pollfd(fd: $0, events: Int16(POLLIN), revents: 0)
            }
            let count = poll(&fds, nfds_t(fds.count), 200)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            for descriptor in fds where descriptor.revents != 0 {
                let n = Darwin.read(descriptor.fd, &buffer, buffer.count)
                if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                    openDescriptors.remove(descriptor.fd)
                }
                guard n > 0, descriptor.fd == outFD else { continue }
                for byte in buffer[..<n] {
                    if byte == 10 {
                        let line = String(decoding: pending, as: UTF8.self)
                        pending.removeAll(keepingCapacity: true)
                        guard let event = parse(line, token: token) else { continue }
                        if event == .ready { sawReady = true }
                        continuation.yield(event)
                        if event == .lost || event == .ended { sawEnd = true; break }
                    } else if pending.count < 4_096 {
                        pending.append(byte)
                    } else {
                        continuation.yield(.lost)
                        sawEnd = true
                        break
                    }
                }
            }
        }
        if !Task<Never, Never>.isCancelled && !sawEnd { continuation.yield(.lost) }
    }
}
