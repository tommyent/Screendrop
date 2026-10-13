import CryptoKit
import Foundation

nonisolated struct CaptureSessionSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let openedAt: Date
    let fingerprint: String
    let baseExtension: String?
    var version = 1

    var title: String {
        "Opened \(openedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }
}

/// Only complete UUID directories are published; an interrupted staging copy
/// cannot become a menu entry or displace one of the five kept sessions.
nonisolated struct CaptureSessionSnapshots {
    let directory: URL

    static func encode<T: Encodable>(_ document: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    func entries() throws -> [CaptureSessionSnapshot] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try metadata(in: $0) }
            .sorted {
                $0.openedAt == $1.openedAt ? $0.id.uuidString > $1.id.uuidString : $0.openedAt > $1.openedAt
            }
    }

    @discardableResult
    func keep(document: Data, baseImage: URL? = nil, openedAt: Date) throws -> [CaptureSessionSnapshot] {
        var fingerprint = SHA256.hash(data: document).map { String(format: "%02x", $0) }.joined()
        if let baseImage {
            let file = try FileHandle(forReadingFrom: baseImage)
            defer { try? file.close() }
            var digest = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
            fingerprint += digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let existing = try entries()
        if existing.first?.fingerprint == fingerprint { return try prune(existing) }

        let ext = baseImage.map { $0.pathExtension.isEmpty ? "png" : $0.pathExtension.lowercased() }
        let entry = CaptureSessionSnapshot(id: UUID(), openedAt: openedAt, fingerprint: fingerprint, baseExtension: ext)
        try validate(entry)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".pending-\(entry.id.uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        if let baseImage, let ext {
            try ScreenshotEditFileTransaction.apply(replacements: [(baseImage, staging.appendingPathComponent("base.\(ext)"))])
        }
        try document.write(to: staging.appendingPathComponent("document.json"), options: .atomic)
        try Self.encode(entry).write(to: staging.appendingPathComponent("session.json"), options: .atomic)
        try manager.moveItem(at: staging, to: folder(for: entry.id))
        return try prune(try entries())
    }

    func read(_ entry: CaptureSessionSnapshot) throws -> (document: Data, baseImage: URL?) {
        let folder = folder(for: entry.id)
        let stored = try metadata(in: folder)
        guard stored == entry else { throw CocoaError(.fileReadCorruptFile) }
        let base = stored.baseExtension.map { folder.appendingPathComponent("base.\($0)") }
        if let base, !FileManager.default.fileExists(atPath: base.path) { throw CocoaError(.fileReadNoSuchFile) }
        return (try Data(contentsOf: folder.appendingPathComponent("document.json")), base)
    }

    private func folder(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func metadata(in folder: URL) throws -> CaptureSessionSnapshot {
        let entry = try JSONDecoder().decode(CaptureSessionSnapshot.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        guard entry.id.uuidString == folder.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
        try validate(entry)
        return entry
    }

    private func validate(_ entry: CaptureSessionSnapshot) throws {
        guard entry.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        if let ext = entry.baseExtension {
            guard !ext.isEmpty, ext.count <= 10, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private func prune(_ entries: [CaptureSessionSnapshot]) throws -> [CaptureSessionSnapshot] {
        for entry in entries.dropFirst(5) { try FileManager.default.removeItem(at: folder(for: entry.id)) }
        return Array(entries.prefix(5))
    }
}
