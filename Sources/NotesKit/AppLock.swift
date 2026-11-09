import Foundation

/// An flock on `Paths.lockFile`. The app holds it for its whole life, so a second copy (or the CLI's
/// spool commands) can tell it's running. The OS drops it when the process dies, crash or not.
public final class AppLock {
    /// -1: running without one (the lock file couldn't be opened or locked).
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// False when running without it: then the lock can't tell whether another copy is running.
    public var isHeld: Bool { fd >= 0 }

    /// Nil only if another process holds it. A lock file that can't be opened or locked (permissions, say) isn't
    /// another copy: that's logged, and the lock comes back not held (`isHeld`), for the caller to decide.
    public static func acquire() -> AppLock? {
        Paths.ensure(Paths.support)
        let fd = open(Paths.lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            Log.note("couldn't open the lock file (\(String(cString: strerror(errno))))")
            return AppLock(fd: -1)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK { return nil }
            Log.note("couldn't lock the lock file (\(String(cString: strerror(error))))")
            return AppLock(fd: -1)
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return AppLock(fd: fd)
    }

    deinit {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }
}
