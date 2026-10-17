import Darwin
import Foundation

/// A process's current working directory, read from kernel metadata.
///
/// A backend that reports OSC 7 tells Bailey where the shell thinks it is, which
/// is authoritative and free. This is the fallback while a backend is waiting
/// for its first report, and the backstop for shells with no OSC 7 integration.
func processWorkingDirectory(pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
        return nil
    }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    return path.isEmpty ? nil : path
}
/// Absolute executable path for a live process, used to identify foreground SSH
/// without trusting user-controlled tab titles or terminal output.
func processExecutablePath(pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    // PROC_PIDPATHINFO_MAXSIZE is a C arithmetic macro Swift does not import;
    // Darwin defines it as four MAXPATHLEN buffers (4096 bytes).
    var buffer = [CChar](repeating: 0, count: 4_096)
    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let path = String(decoding: bytes, as: UTF8.self)
    return path.isEmpty ? nil : path
}
