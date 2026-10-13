import Foundation
import Testing

@MainActor
struct UnsplashWallpaperNamingTests {
    private func photo(id: String, credit: String) -> UnsplashAPI.Photo {
        let url = URL(string: "https://images.unsplash.com/photo-test")!
        return .init(id: id, thumbURL: url, fullURL: url, downloadLocation: url,
                     photographer: credit, profileURL: url, altText: "Test photo")
    }

    @Test func namesNewPicksByCreditAndRetainsUniqueIDs() throws {
        let first = try #require(UnsplashAPI.fileName(for: photo(id: "hwQZLREASZk", credit: "Andrew Coelho")))
        let second = try #require(UnsplashAPI.fileName(for: photo(id: "C_NJKfnTR5A", credit: "Andrew Coelho")))
        #expect(first != second)
        let wallpaper = AnnotationCustomWallpaper(url: URL(fileURLWithPath: "/Wallpapers/Unsplash/\(first)"))
        #expect(wallpaper.title == "Andrew Coelho")
        #expect(wallpaper.accessibilityTitle(ordinal: 2) == "Andrew Coelho")
    }

    @Test func sanitizesNetworkNames() throws {
        let name = try #require(UnsplashAPI.fileName(for: photo(id: "../../safe", credit: "../Ana: [Lee]\n")))
        #expect(!name.contains("/") && !name.contains(":"))
        #expect(!name.hasPrefix("."))
        #expect(!name.contains("\n"))
        #expect(name.hasSuffix(" [safe].jpg"))
        #expect(UnsplashAPI.fileName(for: photo(id: "../", credit: "Ana")) == nil)
        #expect(UnsplashAPI.fileName(for: photo(id: "abc", credit: " \n/:")) == "Wallpaper [abc].jpg")
    }

    @Test func legacyIDsGetAccessibleFallbackWithoutRenamingLocalFiles() {
        let old = AnnotationCustomWallpaper(url: URL(fileURLWithPath: "/Wallpapers/Unsplash/hwQZLREASZk.jpg"))
        #expect(old.title == "Unsplash photo")
        #expect(old.accessibilityTitle(ordinal: 3) == "Wallpaper 3")
        #expect(old.url.lastPathComponent == "hwQZLREASZk.jpg")
        let local = AnnotationCustomWallpaper(url: URL(fileURLWithPath: "/Pictures/Golden Gate [Bridge].jpg"))
        #expect(local.title == "Golden Gate [Bridge]")
        #expect(local.accessibilityTitle(ordinal: 1) == local.title)
    }
}
