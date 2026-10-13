import Foundation

/// Unsplash's photo search, as its API guidelines require it to be used
/// (sd-aeh): the image URLs it returns, used as given; credit to the
/// photographer and Unsplash with utm links; and the photo's
/// `download_location` hit when a photo is picked. Requests go out with the
/// user's own Access Key; demo apps get 50 an hour, image loads not counted.
nonisolated enum UnsplashAPI {
    nonisolated struct Photo: Identifiable, Hashable, Sendable {
        let id: String
        let thumbURL: URL
        /// The raw image sized for a background: 3840 px wide JPEG.
        let fullURL: URL
        let downloadLocation: URL
        let photographer: String
        let profileURL: URL
        let altText: String
    }

    enum Failure: LocalizedError, Equatable {
        case rejectedKey
        case rateLimited
        case http(Int)
        case notAnImage

        var errorDescription: String? {
            switch self {
            case .rejectedKey: "Unsplash didn't accept the Access Key."
            case .rateLimited: "Unsplash's hourly limit is used up. Try again later."
            case .http(let code): "Unsplash returned HTTP \(code)."
            case .notAnImage: "Unsplash didn't send an image."
            }
        }
    }

    static let utmSource = "sukusho"
    static let unsplashURL = URL(string: "https://unsplash.com/?utm_source=\(utmSource)&utm_medium=referral")!
    static let applicationsURL = URL(string: "https://unsplash.com/oauth/applications")!

    static func searchRequest(query: String, accessKey: String) -> URLRequest? {
        var components = URLComponents(string: "https://api.unsplash.com/search/photos")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: "24"),
            URLQueryItem(name: "orientation", value: "landscape"),
        ]
        guard let url = components.url else { return nil }
        return authorized(URLRequest(url: url), accessKey: accessKey)
    }

    static func authorized(_ request: URLRequest, accessKey: String) -> URLRequest {
        var request = request
        request.setValue("Client-ID \(accessKey)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")
        return request
    }

    /// The pick report Unsplash requires. The key goes only to Unsplash's
    /// own API host, whatever the response said the link was.
    static func downloadPing(for photo: Photo, accessKey: String) -> URLRequest? {
        guard photo.downloadLocation.scheme == "https", photo.downloadLocation.host == "api.unsplash.com" else { return nil }
        return authorized(URLRequest(url: photo.downloadLocation), accessKey: accessKey)
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401: throw Failure.rejectedKey
        // Unsplash answers an exhausted hourly quota with 403.
        case 403, 429: throw Failure.rateLimited
        default: throw Failure.http(http.statusCode)
        }
    }

    static func photos(from data: Data) throws -> [Photo] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SearchResponse.self, from: data).results.compactMap(\.photo)
    }

    /// A photo id from the network, made safe to use as a file name.
    static func fileName(for photo: Photo) -> String? {
        let id = photo.id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return id.isEmpty ? nil : "\(id).jpg"
    }

    static func referral(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "utm_source", value: utmSource),
            URLQueryItem(name: "utm_medium", value: "referral"),
        ]
        return components.url ?? url
    }

    private struct SearchResponse: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        struct URLs: Decodable { let raw: URL; let small: URL }
        struct Links: Decodable { let downloadLocation: URL }
        struct User: Decodable {
            struct Links: Decodable { let html: URL }
            let name: String
            let links: Links
        }

        let id: String
        let altDescription: String?
        let urls: URLs
        let links: Links
        let user: User

        var photo: Photo? {
            guard var full = URLComponents(url: urls.raw, resolvingAgainstBaseURL: false) else { return nil }
            full.queryItems = (full.queryItems ?? []) + [
                URLQueryItem(name: "w", value: "3840"),
                URLQueryItem(name: "fm", value: "jpg"),
                URLQueryItem(name: "q", value: "85"),
            ]
            guard let fullURL = full.url else { return nil }
            return Photo(
                id: id,
                thumbURL: urls.small,
                fullURL: fullURL,
                downloadLocation: links.downloadLocation,
                photographer: user.name,
                profileURL: UnsplashAPI.referral(user.links.html),
                altText: altDescription ?? "Photo by \(user.name)"
            )
        }
    }
}
