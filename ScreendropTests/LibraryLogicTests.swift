import Foundation
import Testing

struct LibraryLogicTests {
    private func comment(_ id: String, second: TimeInterval) -> CloudComment {
        CloudComment(id: id, uploadId: "fixture", authorName: "Fixture", authorAvatar: nil,
                     text: "test", timestamp: nil, createdAt: Date(timeIntervalSince1970: second),
                     upload: .init(title: nil, filename: "test.png", mediaType: "image",
                                   shareUrl: "https://example.invalid/fixture", expiresAt: nil))
    }

    @Test func watermarkDistinguishesSameSecondIDs() throws {
        let a = comment("a", second: 1), b = comment("b", second: 2), c = comment("c", second: 2)
        let mark = try #require(CommentWatermark.reading([a, b], after: nil))
        #expect(!mark.isUnread(a) && !mark.isUnread(b))
        #expect(mark.isUnread(c))
        #expect(mark.isUnread(comment("d", second: 3)))
        let both = try #require(CommentWatermark.reading([c], after: mark))
        #expect(both.ids == ["b", "c"])
        #expect(!both.isUnread(b) && !both.isUnread(c))
    }

    @Test func watermarkNeverMovesBackAndSurvivesStorage() throws {
        #expect(CommentWatermark.reading([], after: nil) == nil)
        let mark = try #require(CommentWatermark.reading([comment("b", second: 2)], after: nil))
        #expect(CommentWatermark.reading([comment("a", second: 1)], after: mark) == mark)
        #expect(CommentWatermark.reading([], after: mark) == mark)
        let stored = try JSONDecoder().decode(CommentWatermark.self, from: JSONEncoder().encode(mark))
        #expect(stored == mark && !stored.isUnread(comment("b", second: 2)))
    }

    @Test func uploadPagingKeepsFirstOccurrenceWhenOffsetsShift() throws {
        func row(_ id: Int, title: String = "first") -> String {
            #"{"id":"up\#(id)","url":"https://example.invalid/\#(id)","filename":"test.png","title":"\#(title)","mediaType":"image","createdAt":"2026-10-09T00:00:00Z"}"#
        }
        func page(_ rows: [String]) throws -> [CloudUpload] {
            try CloudUploadList.decode(Data(("{\"uploads\":[" + rows.joined(separator: ",") + "]}").utf8)).uploads
        }
        let first = try page((0..<500).map { row($0) })
        let second = try page([row(499, title: "repeated")] + (500..<1000).map { row($0) })
        let listed = CloudUploadList.deduplicated(first + second)
        #expect(listed.count == 1000)
        #expect(listed.map(\.id) == (0..<1000).map { "up\($0)" })
        #expect(listed[499].title == "first")
    }

    @Test func uploadDedupePreservesUniqueAndEmptyLists() throws {
        #expect(CloudUploadList.deduplicated([]).isEmpty)
        let data = Data(#"{"uploads":[{"id":"a","url":"https://example.invalid/a","filename":"test.png","mediaType":"image","createdAt":"2026-10-09T00:00:00Z"}]}"#.utf8)
        let uploads = try CloudUploadList.decode(data).uploads
        #expect(CloudUploadList.deduplicated(uploads) == uploads)
    }

    @Test func tagMatchesRankExactPrefixThenContainsStably() {
        let tags = ["Onboarding", "Design", "Long note", "On", "Bug", "online"]
        #expect(CaptureTagField.matches("on", in: tags) == ["On", "Onboarding", "online", "Long note"])
        #expect(CaptureTagField.matches("  ON \n", in: tags) == ["On", "Onboarding", "online", "Long note"])
        #expect(CaptureTagField.matches("de", in: tags) == ["Design"])
    }

    @Test func tagMatchesEmptyAndAbsentQueries() {
        let tags = ["Onboarding", "Design", "Long note", "On", "Bug", "online"]
        #expect(CaptureTagField.matches("", in: tags) == tags)
        #expect(CaptureTagField.matches(" \n", in: tags) == tags)
        #expect(CaptureTagField.matches("zzz", in: tags).isEmpty)
        #expect(CaptureTagField.matches("on", in: []).isEmpty)
    }
}
