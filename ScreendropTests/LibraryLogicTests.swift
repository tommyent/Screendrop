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
