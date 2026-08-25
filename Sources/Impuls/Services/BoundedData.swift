import Foundation

enum BoundedDataError: Error, Equatable {
    case limitExceeded
    /// The path did not resolve to a regular file. FIFOs, devices and sockets
    /// are rejected before any read is attempted, because reading one blocks
    /// on a peer that may never arrive and no byte budget can bound that wait.
    case notARegularFile
}

/// Accumulates streamed bytes without ever growing beyond the declared budget.
/// The subtraction form avoids integer overflow when an untrusted chunk is
/// larger than the remaining capacity.
struct BoundedDataAccumulator {
    let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ chunk: Data) throws {
        guard data.count <= maximumBytes,
              chunk.count <= maximumBytes - data.count else {
            throw BoundedDataError.limitExceeded
        }
        data.append(chunk)
    }
}

/// Reads at most `maximumBytes + 1` bytes. Unlike a size preflight followed by
/// `Data(contentsOf:)`, this remains bounded even if the file is replaced or
/// grows while it is being read.
///
/// A byte budget bounds *how much* is read, not *how long* the read waits. A
/// FIFO, device or socket answers `open`/`read` only when a peer decides to,
/// so a budget alone leaves the caller waiting indefinitely on something that
/// is not a file at all. The descriptor is therefore opened non-blocking and
/// checked before a single byte is requested.
enum BoundedFileReader {
    static func read(from url: URL, maximumBytes: Int) throws -> Data {
        precondition(maximumBytes >= 0)
        let handle = try openRegularFile(at: url)
        defer { try? handle.close() }

        var accumulator = BoundedDataAccumulator(maximumBytes: maximumBytes)
        while true {
            let remaining = maximumBytes - accumulator.data.count
            // Avoid `remaining + 1` overflowing when this reusable helper is
            // given `Int.max`; current application budgets are smaller, but a
            // bounds primitive should remain correct for every valid input.
            let requestSize = remaining < 64 * 1_024 ? remaining + 1 : 64 * 1_024
            guard let chunk = try handle.read(upToCount: requestSize), !chunk.isEmpty else {
                return accumulator.data
            }
            try accumulator.append(chunk)
        }
    }

    /// Opens `url` and returns a handle only when the *opened descriptor* is a
    /// regular file.
    ///
    /// `O_NONBLOCK` is what makes the check reachable: opening a FIFO with a
    /// blocking descriptor waits for a writer, so a check performed after a
    /// plain `open` would never run. It is cleared again for the regular files
    /// that survive, which never report `EAGAIN` anyway.
    ///
    /// The type is read with `fstat` on the descriptor rather than `stat` on
    /// the path, so the answer describes the file actually opened. Checking the
    /// path first and opening afterwards would leave a window in which the two
    /// are no longer the same file.
    private static func openRegularFile(at url: URL) throws -> FileHandle {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let failure = errno
            close(descriptor)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(failure),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw BoundedDataError.notARegularFile
        }

        // The flag has done its job. Regular files ignore it, but clearing it
        // keeps the handle indistinguishable from an ordinary blocking read.
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }

        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
