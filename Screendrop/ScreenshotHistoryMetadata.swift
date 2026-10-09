import Foundation

/// Keep an index this build cannot fully read intact, even when later mutations try to save it.
struct ScreenshotHistoryMetadata<Row: Codable> {
    private(set) var isReadOnly = true
    private(set) var unreadableRowIndices: [Int] = []

    mutating func load(from url: URL) -> [Row] {
        isReadOnly = true
        unreadableRowIndices = []
        do {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
                    isReadOnly = false
                    return []
                }
                throw error
            }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var items: [Row] = []
            for (index, row) in rows.enumerated() {
                do {
                    let rowData = try JSONSerialization.data(withJSONObject: row, options: .fragmentsAllowed)
                    items.append(try JSONDecoder().decode(Row.self, from: rowData))
                } catch {
                    unreadableRowIndices.append(index)
                    NSLog("[Screendrop] Could not read history row %d; keeping the original index read-only: %@", index, error.localizedDescription)
                }
            }
            isReadOnly = !unreadableRowIndices.isEmpty
            return items
        } catch {
            NSLog("[Screendrop] Could not read history; keeping the original index read-only: %@", error.localizedDescription)
            return []
        }
    }

    func save(_ items: [Row], to url: URL) throws {
        guard !isReadOnly else {
            throw NSError(domain: "Screendrop.History", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The Library index could not be fully read. The original history.json has been preserved; use a compatible Sukusho build before saving Library changes."
            ])
        }
        let data = try JSONEncoder().encode(items)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
