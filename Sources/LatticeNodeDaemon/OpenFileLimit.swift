import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The process's limit on open files, raised at start to what the system
/// allows, as Bitcoin Core (`RaiseFileDescriptorLimit`) and geth
/// (`fdlimit.Raise`) do: each hosted chain's Volume store holds about
/// thirteen open files, so a shell's default soft limit (256 on macOS) would
/// otherwise bound how many chains a node can host. Only the soft limit
/// moves, never past the hard limit, and on macOS never past the kernel's
/// per-process maximum, which `setrlimit` enforces however high the hard
/// limit reads.
enum OpenFileLimit {
    #if os(Linux)
    private static let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
    #else
    private static let resource = RLIMIT_NOFILE
    #endif

    /// The soft limit after raising it as far as allowed; nil when it could
    /// not be read.
    @discardableResult
    static func raise() -> UInt64? {
        var limit = rlimit()
        guard getrlimit(resource, &limit) == 0 else { return nil }
        var target = limit.rlim_max
        #if canImport(Darwin)
        var perProcess: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0, perProcess > 0 {
            target = min(target, rlim_t(perProcess))
        }
        #else
        // An unlimited hard limit is not a soft limit Linux takes: the
        // kernel's per-process maximum (`fs.nr_open`) is, or failing that
        // its default, 1,048,576.
        if target == RLIM_INFINITY {
            let read = (try? String(contentsOfFile: "/proc/sys/fs/nr_open", encoding: .utf8))
                .flatMap { rlim_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            target = read ?? 1_048_576
        }
        #endif
        guard target > limit.rlim_cur else { return UInt64(limit.rlim_cur) }
        var raised = limit
        raised.rlim_cur = target
        guard setrlimit(resource, &raised) == 0 else { return UInt64(limit.rlim_cur) }
        return UInt64(target)
    }
}
