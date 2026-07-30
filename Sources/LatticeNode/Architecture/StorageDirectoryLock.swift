import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum StorageDirectoryLockError: Error, Equatable {
    case unavailable
    case alreadyLocked
}

/// A process-lifetime writer lock for one node storage directory.
final class StorageDirectoryLock: Sendable {
    private let descriptor: Int32

    init(directory: URL) throws {
        let path = directory.appendingPathComponent(".lattice-node.lock").path
        let descriptor = open(
            path,
            O_RDWR | O_CREAT | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw StorageDirectoryLockError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                throw StorageDirectoryLockError.alreadyLocked
            }
            throw StorageDirectoryLockError.unavailable
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
