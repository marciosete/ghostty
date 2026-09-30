import Darwin
import Foundation

/// What the kernel says about the processes running as this user.
enum RunningProcess {
    /// Every process id in use.
    static func all() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started since counting.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return [] }
        return Array(pids.prefix(Int(found)).filter { $0 > 0 })
    }

    /// The processes the process started that are still running.
    static func children(_ pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// The process that started the process.
    static func parent(_ pid: pid_t) -> pid_t? {
        bsdInfo(pid).map { pid_t($0.pbi_ppid) }
    }

    /// The process is still running.
    static func isRunning(_ pid: pid_t) -> Bool {
        bsdInfo(pid) != nil
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// The name of the process's executable, such as `sh`.
    static func name(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's arguments, its command first.
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        // The argument count, the executable's path, padding, then the arguments, each
        // ending with a zero, then the environment.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// The process's working directory.
    static func directory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { path(in: $0) }
    }

    /// When the process started.
    static func startTime(_ pid: pid_t) -> Date? {
        guard let info = bsdInfo(pid) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The regular file the process writes its output to, or nil when its output goes
    /// to a terminal or a pipe.
    static func outputFile(_ pid: pid_t) -> URL? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, STDOUT_FILENO, PROC_PIDFDVNODEPATHINFO, &info, size) == size,
              mode_t(truncatingIfNeeded: info.pvip.vip_vi.vi_stat.vst_mode) & S_IFMT == S_IFREG else { return nil }
        return withUnsafeBytes(of: &info.pvip.vip_path) { path(in: $0) }.map(URL.init(fileURLWithPath:))
    }

    private static func path(in bytes: UnsafeRawBufferPointer) -> String? {
        let characters = bytes.prefix { $0 != 0 }
        return characters.isEmpty ? nil : String(decoding: characters, as: UTF8.self)
    }
}
