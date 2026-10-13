import Foundation

// swiftc -parse-as-library -default-isolation MainActor scripts/check-unsplash-api.swift \
//   Screendrop/UnsplashAPI.swift -o /private/tmp/check-unsplash-api && /private/tmp/check-unsplash-api

// Unsplash search parsing, file names and status mapping, with no network or app.
@main
struct UnsplashAPIChecks {
    static func main() throws {
        let json = """
        {"total": 2, "total_pages": 1, "results": [
          {"id": "abc-123_X", "alt_description": "a beach",
           "urls": {"raw": "https://images.unsplash.com/photo-1?ixid=k1", "small": "https://images.unsplash.com/photo-1?w=400"},
           "links": {"download_location": "https://api.unsplash.com/photos/abc-123_X/download?ixid=k1"},
           "user": {"name": "Ana Lee", "links": {"html": "https://unsplash.com/@ana"}}},
          {"id": "../../etc", "alt_description": null,
           "urls": {"raw": "https://images.unsplash.com/photo-2", "small": "https://images.unsplash.com/photo-2?w=400"},
           "links": {"download_location": "https://api.unsplash.com/photos/x/download"},
           "user": {"name": "Bo", "links": {"html": "https://unsplash.com/@bo"}}}
        ]}
        """
        let photos = try UnsplashAPI.photos(from: Data(json.utf8))
        precondition(photos.count == 2)
        let first = photos[0]
        precondition(first.fullURL.absoluteString == "https://images.unsplash.com/photo-1?ixid=k1&w=3840&fm=jpg&q=85")
        precondition(first.profileURL.absoluteString == "https://unsplash.com/@ana?utm_source=sukusho&utm_medium=referral")
        precondition(first.downloadLocation.absoluteString.hasSuffix("/download?ixid=k1"))
        precondition(UnsplashAPI.fileName(for: first) == "Ana Lee [abc-123_X].jpg")
        precondition(photos[1].altText == "Photo by Bo")
        // A hostile id can't climb out of the wallpapers folder.
        precondition(UnsplashAPI.fileName(for: photos[1]) == "Bo [etc].jpg")

        precondition(UnsplashAPI.downloadPing(for: first, accessKey: "KEY")?.value(forHTTPHeaderField: "Authorization") == "Client-ID KEY")
        let elsewhere = UnsplashAPI.Photo(id: "x", thumbURL: first.thumbURL, fullURL: first.fullURL,
                                          downloadLocation: URL(string: "https://example.com/collect")!,
                                          photographer: "x", profileURL: first.profileURL, altText: "x")
        precondition(UnsplashAPI.downloadPing(for: elsewhere, accessKey: "KEY") == nil)

        let request = UnsplashAPI.searchRequest(query: "sunset & sea", accessKey: "KEY")!
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Client-ID KEY")
        precondition(request.url!.absoluteString.contains("query=sunset%20%26%20sea"))

        func status(_ code: Int) -> UnsplashAPI.Failure? {
            let response = HTTPURLResponse(url: URL(string: "https://api.unsplash.com")!, statusCode: code,
                                           httpVersion: nil, headerFields: nil)!
            do { try UnsplashAPI.check(response); return nil } catch { return error as? UnsplashAPI.Failure }
        }
        precondition(status(200) == nil)
        precondition(status(401) == .rejectedKey)
        precondition(status(403) == .rateLimited)
        precondition(status(500) == .http(500))
        print("unsplash api checks passed")
    }
}
