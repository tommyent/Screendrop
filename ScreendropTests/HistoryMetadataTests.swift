import Foundation
import Testing

@MainActor
struct HistoryMetadataTests {
    private struct Row: Codable, Equatable {
        enum Kind: String, Codable { case image, video }
        var name: String
        var kind: Kind = .image
        var tags: [String] = ["client"]
        var cloudURL = "https://example.invalid/share"
    }

    private func withIndex(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Screendrop-HistoryTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder.appendingPathComponent("history.json"))
    }

    @Test func oneFutureRowKeepsReadableRowsAndCannotRewriteOriginal() throws {
        try withIndex { url in
            let good = (0..<1000).map { Row(name: "capture-\($0)") }
            var rows = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [[String: Any]])
            rows.insert(["name": "future", "kind": "gif", "tags": ["important"]], at: 500)
            let original = try JSONSerialization.data(withJSONObject: rows)
            try original.write(to: url)
            var index = ScreenshotHistoryMetadata<Row>()
            #expect(index.load(from: url) == good)
            #expect(index.isReadOnly && index.unreadableRowIndices == [500])
            #expect(throws: (any Error).self) { try index.save([Row(name: "next-capture")], to: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func scalarAndMalformedRowsStayOnDisk() throws {
        try withIndex { url in
            let original = Data(#"[null,42,{"name":"good","kind":"image","tags":[],"cloudURL":"link"},{"name":false}]"#.utf8)
            try original.write(to: url)
            var index = ScreenshotHistoryMetadata<Row>()
            #expect(index.load(from: url).map(\.name) == ["good"])
            #expect(index.unreadableRowIndices == [0, 1, 3])
            #expect(throws: (any Error).self) { try index.save([], to: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test(arguments: ["[", "{}", "null"])
    func unreadableWholeIndexCannotBeOverwritten(_ text: String) throws {
        try withIndex { url in
            let original = Data(text.utf8)
            try original.write(to: url)
            var index = ScreenshotHistoryMetadata<Row>()
            #expect(index.load(from: url).isEmpty)
            #expect(index.isReadOnly)
            #expect(throws: (any Error).self) { try index.save([Row(name: "new")], to: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func missingOrFullyReadableIndexCanSaveAndReload() throws {
        try withIndex { url in
            var index = ScreenshotHistoryMetadata<Row>()
            #expect(index.load(from: url).isEmpty && !index.isReadOnly)
            let rows = [Row(name: "capture")]
            try index.save(rows, to: url)
            #expect(index.load(from: url) == rows && !index.isReadOnly)
            try index.save([], to: url)
            #expect(index.load(from: url).isEmpty && !index.isReadOnly)
        }
    }
}
