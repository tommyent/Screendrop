import Foundation
import Observation
import SwiftUI

/// The background picker's Unsplash search (sd-aeh), with the user's own
/// Access Key kept in the Keychain.
@Observable
final class UnsplashWallpaperSearch {
    static let shared = UnsplashWallpaperSearch()

    private static let keychainKey = "unsplash_access_key"

    private(set) var accessKey: String
    private(set) var results: [UnsplashAPI.Photo] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private(set) var downloadingID: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private init() {
        accessKey = CloudCredentialStore.getKeychainItem(key: Self.keychainKey) ?? ""
    }

    func setAccessKey(_ key: String) {
        searchTask?.cancel()
        isSearching = false
        accessKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if accessKey.isEmpty {
            CloudCredentialStore.deleteKeychainItem(key: Self.keychainKey)
        } else {
            CloudCredentialStore.setKeychainItem(key: Self.keychainKey, value: accessKey)
        }
        results = []
        errorMessage = nil
    }

    /// One API request per submitted search, so the hourly quota lasts.
    func search(_ query: String) {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let request = UnsplashAPI.searchRequest(query: query, accessKey: accessKey) else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        errorMessage = nil
        searchTask = Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                try UnsplashAPI.check(response)
                let photos = try UnsplashAPI.photos(from: data)
                guard !Task.isCancelled else { return }
                results = photos
                if photos.isEmpty { errorMessage = "No photos found." }
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    /// Reports the pick to Unsplash, as its rules require, and fetches the
    /// photo at background size into the wallpapers folder.
    /// shortcut: the renderer draws local files, so the pick is kept as a
    /// copy; if Unsplash ever objects, render from `fullURL` instead.
    func use(_ photo: UnsplashAPI.Photo) async -> URL? {
        guard let fileName = UnsplashAPI.fileName(for: photo) else { return nil }
        downloadingID = photo.id
        defer { downloadingID = nil }
        errorMessage = nil
        do {
            if let ping = UnsplashAPI.downloadPing(for: photo, accessKey: accessKey) {
                _ = try? await URLSession.shared.data(for: ping)
            }

            let (data, response) = try await URLSession.shared.data(from: photo.fullURL)
            try UnsplashAPI.check(response)
            guard response.mimeType?.hasPrefix("image/") == true else { throw UnsplashAPI.Failure.notAnImage }
            let directory = AnnotationWallpaperStore.wallpapersDirectory
                .appendingPathComponent("Unsplash", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(fileName)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

/// Search field, results and credits under the picker's Recent wallpapers.
struct UnsplashWallpaperSearchView: View {
    @Bindable var search: UnsplashWallpaperSearch
    let onPick: (URL) -> Void

    @State private var query = ""
    @State private var draftKey = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if search.accessKey.isEmpty {
                keySetup
            } else {
                searchField
                if !search.results.isEmpty { resultsGrid }
                if let message = search.errorMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                footer
            }
        }
    }

    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search Unsplash with your own free Access Key.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Get one at unsplash.com", destination: UnsplashAPI.applicationsURL)
                .font(.system(size: 11))
            HStack(spacing: 6) {
                SecureField("Access Key", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                Button("Save", action: saveKey)
                    .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("Search Unsplash", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { search.search(query) }
            if search.isSearching {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var resultsGrid: some View {
        ScrollView { resultTiles }
            .frame(maxHeight: 320)
    }

    private var resultTiles: some View {
        LazyVGrid(columns: columns, spacing: 7) {
            ForEach(search.results) { photo in
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        Task {
                            if let url = await search.use(photo) { onPick(url) }
                        }
                    } label: {
                        Color.clear
                            .aspectRatio(1.35, contentMode: .fit)
                            .overlay {
                                AsyncImage(url: photo.thumbURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.secondary.opacity(0.15)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous))
                            .overlay {
                                if search.downloadingID == photo.id { ProgressView().controlSize(.small) }
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(search.downloadingID != nil)
                    .help(photo.altText)
                    .accessibilityLabel(photo.altText)

                    Link(photo.photographer, destination: photo.profileURL)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 12, alignment: .leading)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Link("Photos from Unsplash", destination: UnsplashAPI.unsplashURL)
            Spacer()
            Button("Remove Key") { search.setAccessKey("") }
                .buttonStyle(.link)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func saveKey() {
        search.setAccessKey(draftKey)
        draftKey = ""
    }
}
