import Foundation
import Observation

@MainActor @Observable
final class FreeToUseMusicPickerModel {
    var searchText = ""
    var browse: FreeToUseMusicAPI.Browse = .all
    private(set) var categories: [FreeToUseMusicAPI.Category] = []
    private(set) var tracks: [FreeToUseMusicAPI.Track] = []
    private(set) var nextOffset: Int?
    private(set) var isLoading = false
    private(set) var categoriesError: String?
    private(set) var tracksError: String?
    private(set) var downloadingID: String?
    private(set) var downloadError: String?
    private(set) var failedDownloadID: String?
    let preview = FreeToUseMusicPreview()

    @ObservationIgnored private let api: FreeToUseMusicAPI
    @ObservationIgnored private var tracksRequestID: UUID?
    @ObservationIgnored private var moreTask: Task<Void, Never>?
    @ObservationIgnored private(set) var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var failedOffset: TimeInterval = 0

    init(api: FreeToUseMusicAPI = FreeToUseMusicAPI()) { self.api = api }

    func loadCategories() async {
        guard !isClosed, !Task.isCancelled else { return }
        categoriesError = nil
        do {
            let result = try await api.categories()
            guard !isClosed, !Task.isCancelled else { return }
            categories = result
        }
        catch {
            guard !Task.isCancelled, !isClosed else { return }
            categoriesError = FreeToUseMusicAPI.message(for: error)
        }
    }

    func select(_ category: FreeToUseMusicAPI.Category?) {
        searchText = ""
        browse = category.map { .category($0) } ?? .all
    }

    func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { browse = .search(query) }
        else if case .search = browse { browse = .all }
    }

    func loadTracks(reset: Bool = true) async {
        guard !isClosed, !Task.isCancelled else { return }
        if reset {
            moreTask?.cancel()
            tracks = []
            nextOffset = nil
            preview.stop()
        }
        let requestID = UUID()
        tracksRequestID = requestID
        let requestedBrowse = browse
        isLoading = true
        tracksError = nil
        defer { if tracksRequestID == requestID { isLoading = false } }
        do {
            let page = try await api.tracks(in: requestedBrowse, offset: reset ? 0 : (nextOffset ?? 0))
            try Task.checkCancellation()
            guard tracksRequestID == requestID, browse == requestedBrowse, !isClosed else { return }
            var seen = Set(tracks.map(\.id))
            tracks += page.data.filter { $0.isUsable && seen.insert($0.id).inserted }
            nextOffset = page.nextOffset
        } catch {
            guard !Task.isCancelled, tracksRequestID == requestID, !isClosed else { return }
            tracksError = FreeToUseMusicAPI.message(for: error)
        }
    }

    func loadMore() {
        guard !isLoading, nextOffset != nil else { return }
        moreTask = Task { await loadTracks(reset: false) }
    }

    func use(_ track: FreeToUseMusicAPI.Track,
             setBackgroundMusic: @escaping (URL, String, String?, TimeInterval) -> Void,
             dismiss: @escaping () -> Void) {
        guard downloadingID == nil, !isClosed, track.isUsable else { return }
        let position = preview.trackID == track.id ? preview.selectionPosition : (failedDownloadID == track.id ? failedOffset : 0)
        let offset = track.startOffset(at: position)
        preview.stop()
        downloadingID = track.id
        downloadError = nil
        failedDownloadID = nil
        downloadTask = Task {
            defer { downloadingID = nil; downloadTask = nil }
            do {
                let fileURL = try await api.download(track)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                try Task.checkCancellation()
                guard !isClosed else { return }
                guard await RecordingReplacementAudio.load(url: fileURL, displayName: track.displayName) != nil else {
                    throw FreeToUseMusicAPI.Failure.invalidAudio
                }
                try Task.checkCancellation()
                guard !isClosed else { return }
                // The Studio method copies synchronously before this temporary file is removed.
                setBackgroundMusic(fileURL, track.displayName, track.credit, offset)
                dismiss()
            } catch {
                guard !Task.isCancelled, !isClosed else { return }
                failedDownloadID = track.id
                failedOffset = offset
                downloadError = FreeToUseMusicAPI.message(for: error)
            }
        }
    }

    func close() {
        isClosed = true
        tracksRequestID = nil
        moreTask?.cancel()
        downloadTask?.cancel()
        preview.stop()
    }
}
