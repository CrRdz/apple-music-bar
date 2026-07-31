import Darwin
import Foundation

enum AppIdentity {
    static let bundleIdentifier = "dev.local.AppleMusicBar"
}

final class AppInstanceLock {
    private static let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(AppIdentity.bundleIdentifier).lock")

    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() -> AppInstanceLock? {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }

        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }

        return AppInstanceLock(fileDescriptor: fd)
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
