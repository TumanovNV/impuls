import Foundation

enum BoundedDataError: Error, Equatable {
    case limitExceeded
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
enum BoundedFileReader {
    static func read(from url: URL, maximumBytes: Int) throws -> Data {
        precondition(maximumBytes >= 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var accumulator = BoundedDataAccumulator(maximumBytes: maximumBytes)
        while true {
            let remaining = maximumBytes - accumulator.data.count
            let requestSize = min(64 * 1_024, remaining + 1)
            guard let chunk = try handle.read(upToCount: requestSize), !chunk.isEmpty else {
                return accumulator.data
            }
            try accumulator.append(chunk)
        }
    }
}
