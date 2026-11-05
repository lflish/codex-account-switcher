import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads and writes usage-stats.json with atomic writes and 0600 permissions.
public actor UsageStatsStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private var cached: StoredUsageStats?

    public init(baseURL: URL, fileManager: FileManager = .default) {
        self.fileURL = baseURL.appending(path: "usage-stats.json")
        self.fileManager = fileManager
    }

    public func load() throws -> StoredUsageStats {
        if let cached { return cached }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cached = .empty
            return .empty
        }
        let data = try Data(contentsOf: fileURL)
        let loaded = try Self.decoder.decode(StoredUsageStats.self, from: data)
        cached = loaded
        return loaded
    }

    public func save(_ stats: StoredUsageStats) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try Self.encoder.encode(stats)
        try secureAtomicWrite(bytes, to: fileURL)
        cached = stats
    }

    public func update(accountID: String, stats: AccountUsageStats, status: AccountSyncStatus) throws {
        var stored = try load()
        stored.accounts[accountID] = stats
        stored.syncStatuses[accountID] = status
        try save(stored)
    }

    public func updateStatus(accountID: String, status: AccountSyncStatus) throws {
        var stored = try load()
        stored.syncStatuses[accountID] = status
        try save(stored)
    }

    // Follows the same pattern as AccountStore.secureAtomicWrite
    private func secureAtomicWrite(_ bytes: Data, to destination: URL) throws {
        let temporary = destination
            .deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).switcher-\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }

        do {
            try bytes.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                    guard count > 0 else { throw currentPOSIXError() }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
            guard close(descriptor) == 0 else { throw currentPOSIXError() }
        } catch {
            _ = close(descriptor)
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        if rename(temporary.path, destination.path) != 0 {
            let error = currentPOSIXError()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
