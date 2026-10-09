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
        let mark = try #require(FeedWatermark.reading([a, b], after: nil))
        #expect(!mark.isUnread(a) && !mark.isUnread(b))
        #expect(mark.isUnread(c))
        #expect(mark.isUnread(comment("d", second: 3)))
        let both = try #require(FeedWatermark.reading([c], after: mark))
        #expect(both.ids == ["b", "c"])
        #expect(!both.isUnread(b) && !both.isUnread(c))
    }

    @Test func watermarkNeverMovesBackAndSurvivesStorage() throws {
        #expect(FeedWatermark.reading([CloudComment](), after: nil) == nil)
        let mark = try #require(FeedWatermark.reading([comment("b", second: 2)], after: nil))
        #expect(FeedWatermark.reading([comment("a", second: 1)], after: mark) == mark)
        #expect(FeedWatermark.reading([CloudComment](), after: mark) == mark)
        let stored = try JSONDecoder().decode(FeedWatermark.self, from: JSONEncoder().encode(mark))
        #expect(stored == mark && !stored.isUnread(comment("b", second: 2)))
    }

    private func like(_ id: String, second: TimeInterval) -> CloudLike {
        CloudLike(id: id, uploadId: "fixture", createdAt: Date(timeIntervalSince1970: second),
                  upload: .init(title: nil, filename: "test.png", mediaType: "image",
                                shareUrl: "https://example.invalid/fixture", expiresAt: nil))
    }

    @Test func watermarkReadsLikesLikeComments() throws {
        let a = like("a", second: 1), b = like("b", second: 2), c = like("c", second: 2)
        let mark = try #require(FeedWatermark.reading([a, b], after: nil))
        #expect(!mark.isUnread(a) && !mark.isUnread(b))
        #expect(mark.isUnread(c) && mark.isUnread(like("d", second: 3)))
        #expect(FeedWatermark.reading([like("e", second: 1)], after: mark) == mark)
        let stored = try JSONDecoder().decode(FeedWatermark.self, from: JSONEncoder().encode(mark))
        #expect(stored == mark && !stored.isUnread(b))
    }

    @Test func likePageDecodesTheSpecShape() throws {
        let data = Data(#"""
        {"likes":[
          {"id":"lk_b","uploadId":"up1","createdAt":"2026-10-09T05:55:30Z",
           "upload":{"title":null,"filename":"shot.png","mediaType":"image","shareUrl":"https://example.invalid/up1","expiresAt":null}},
          {"id":"lk_a","uploadId":"up2","createdAt":"2026-10-09T05:55:30Z",
           "upload":{"title":"Demo","filename":"clip.mov","mediaType":"video","shareUrl":"https://example.invalid/up2","expiresAt":"2026-11-01T00:00:00Z"}},
          {"id":"lk_c","uploadId":"up3","createdAt":"2026-10-09T05:50:00Z",
           "upload":{"title":"","filename":"x.png","mediaType":"image","shareUrl":"https://example.invalid/up3","expiresAt":null}}
        ],"next":500}
        """#.utf8)
        let page = try CloudLikeList.decode(data)
        #expect(page.next == 500)
        #expect(page.likes.map(\.uploadName) == ["shot.png", "Demo", "x.png"])
        #expect(page.likes.map(\.isVideo) == [false, true, false])
        #expect(page.likes[0].createdAt == Date(timeIntervalSince1970: 1_791_525_330))
        let empty = try CloudLikeList.decode(Data(#"{"likes":[],"next":null}"#.utf8))
        #expect(empty.likes.isEmpty && empty.next == nil)
    }

    @Test func likeRequestAndShareLink() throws {
        let request = try #require(CloudLikeList.request(workerBase: "https://example.invalid", token: "t0k", offset: 500))
        #expect(request.url?.absoluteString == "https://example.invalid/api/likes?limit=500&offset=500")
        #expect(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
        #expect(CloudLikeList.request(workerBase: "not a url", token: "t", offset: 0) == nil)
        func link(_ shareUrl: String) -> URL? {
            CloudLikeList.shareLink(for: CloudLike(id: "a", uploadId: "u", createdAt: .distantPast, upload: .init(
                title: nil, filename: "test.png", mediaType: "image", shareUrl: shareUrl, expiresAt: nil)))
        }
        #expect(link("https://example.invalid/u")?.absoluteString == "https://example.invalid/u")
        #expect(link("javascript:alert(1)") == nil)
        #expect(link("file:///etc/hosts") == nil)
        #expect(link("https://") == nil)
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
