import AppKit
import ImageIO
import SwiftUI

/// The Library's Cloud page: every upload on the Worker, including those
/// whose local capture has gone to the Trash, with their links and a way to
/// delete them. A Worker without GET /api/uploads gets the uploads History
/// still knows about instead.
@MainActor
@Observable
final class CloudLibraryModel {
    static let shared = CloudLibraryModel()
    /// The Cloud page shows in place of the captures.
    var isShown = false
    var selection: CloudUpload.ID?
    var pendingDelete: CloudUpload?
    private(set) var uploads: [CloudUpload] = []
    /// Listed from History because the Worker can't list uploads.
    private(set) var isHistoryFallback = false
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var deletingIDs: Set<String> = []

    private init() {}

    var selectedUpload: CloudUpload? { uploads.first { $0.id == selection } }

    /// Uploads matching the Library's search, in its sort order.
    var visibleUploads: [CloudUpload] {
        let library = CaptureLibraryModel.shared
        let query = library.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? uploads : uploads.filter {
            $0.name.localizedStandardContains(query) || $0.filename.localizedStandardContains(query)
        }
        switch library.sortOrder {
        case .oldest: return matching.sorted { $0.createdAt < $1.createdAt }
        case .name: return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .newest, .modified: return matching.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Library captures by the upload ID in their cloud link.
    var localItems: [String: CaptureLibraryItem] {
        CaptureLibraryModel.shared.items.reduce(into: [:]) { result, item in
            if let id = CloudUploadList.uploadID(of: item.cloudURL) { result[id] = item }
        }
    }

    func refresh() {
        guard !isLoading else { return }
        guard CloudUploader.shared.isConfigured else {
            uploads = []
            hasLoaded = true
            return
        }
        isLoading = true
        Task {
            defer {
                isLoading = false
                hasLoaded = true
            }
            do {
                uploads = try await CloudUploader.shared.listUploads()
                isHistoryFallback = false
                loadError = nil
            } catch CloudUploadError.listUnavailable {
                uploads = Self.historyUploads()
                isHistoryFallback = true
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            if let selection, !uploads.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }

    /// Uploads whose capture is still in History, newest first.
    private static func historyUploads() -> [CloudUpload] {
        var seen: Set<String> = []
        return ScreenshotHistoryStore.shared.items.compactMap { item in
            guard let link = item.cloudURL, let id = CloudUploadList.uploadID(of: link),
                  seen.insert(id).inserted else { return nil }
            return CloudUpload(
                id: id, url: link, title: item.displayName, filename: item.fileName,
                mediaType: item.isVideo ? "video" : "image", size: nil, duration: item.duration,
                createdAt: item.createdAt, views: nil, thumbnailUrl: nil
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func open(_ upload: CloudUpload) {
        if let url = URL(string: upload.url) { NSWorkspace.shared.open(url) }
    }

    func copyLink(_ upload: CloudUpload) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(upload.url, forType: .string)
    }

    /// Selects the upload's capture in All Captures.
    func showInLibrary(_ item: CaptureLibraryItem) {
        isShown = false
        let library = CaptureLibraryModel.shared
        library.tagFilter = nil
        library.searchText = ""
        library.filter = .all
        library.selection = [item.id]
    }

    /// The same call as the inspector's Delete from Cloud, and like it,
    /// clears the link from the capture's History entries.
    func delete(_ upload: CloudUpload) {
        guard deletingIDs.insert(upload.id).inserted else { return }
        Task {
            defer { deletingIDs.remove(upload.id) }
            do {
                try await CloudUploader.shared.deleteFromCloud(uploadID: upload.id)
                let history = ScreenshotHistoryStore.shared
                for item in history.items where CloudUploadList.uploadID(of: item.cloudURL) == upload.id {
                    history.setLibraryCloudURL(id: item.id, cloudURL: nil)
                }
                uploads.removeAll { $0.id == upload.id }
                if selection == upload.id { selection = nil }
            } catch {
                CaptureLibraryModel.shared.errorMessage = error.localizedDescription
            }
        }
    }
}

struct CloudLibraryPage: View {
    let cloud: CloudLibraryModel
    let layout: CaptureLibraryLayout
    let cardWidth: CGFloat
    @State private var width: CGFloat = 800

    var body: some View {
        let uploads = cloud.visibleUploads
        let local = cloud.localItems
        Group {
            if !CloudUploader.shared.isConfigured {
                ContentUnavailableView {
                    Label("Cloud Isn’t Set Up", systemImage: "icloud.slash")
                } description: {
                    Text("Add your Worker in Settings to share captures and manage your uploads here.")
                } actions: {
                    Button("Open Cloud Settings") { SettingsWindowController.show(tab: .cloud) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else if !cloud.hasLoaded {
                ProgressView("Loading Uploads…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = cloud.loadError, cloud.uploads.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Uploads", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { cloud.refresh() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else if uploads.isEmpty {
                let search = CaptureLibraryModel.shared.searchText
                ContentUnavailableView {
                    if search.isEmpty {
                        Label("No Uploads", systemImage: "icloud")
                    } else {
                        Label("No Results for “\(search)”", systemImage: "magnifyingglass")
                    }
                } description: {
                    Text(search.isEmpty
                        ? "Captures you share to the cloud appear here."
                        : "Check the spelling or try a new search.")
                }
            } else {
                ScrollView {
                    if layout == .grid { grid(uploads, local: local) } else { list(uploads, local: local) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if cloud.isHistoryFallback {
                Label("Showing uploads whose capture is still in the Library. Update the Worker to see every upload.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .onAppear { cloud.refresh() }
        .alert("Delete from cloud?", isPresented: Binding(
            get: { cloud.pendingDelete != nil }, set: { if !$0 { cloud.pendingDelete = nil } }
        ), presenting: cloud.pendingDelete) { upload in
            Button("Delete", role: .destructive) {
                cloud.delete(upload)
                cloud.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { cloud.pendingDelete = nil }
        } message: { upload in
            Text("This permanently removes the cloud copy and breaks its share link."
                + (local[upload.id] == nil ? "" : " Your local capture stays in the Library."))
        }
    }

    /// The Library grid's spacing: cards keep one size, and the leftover
    /// width is shared evenly by the gaps and both side margins.
    private func grid(_ uploads: [CloudUpload], local: [String: CaptureLibraryItem]) -> some View {
        let cell = min(cardWidth, max(100, width - 32))
        let columns = max(1, Int((width - 16) / (cell + 16)))
        let space = max(16, floor((width - CGFloat(columns) * cell) / CGFloat(columns + 1)))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: space), count: columns), spacing: 16) {
            ForEach(uploads) { upload in
                card(upload, local: local[upload.id])
                    .frame(width: cell, height: floor(cell * 0.625) + 62)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private func list(_ uploads: [CloudUpload], local: [String: CaptureLibraryItem]) -> some View {
        LazyVStack(spacing: 6) {
            ForEach(uploads) { upload in
                card(upload, local: local[upload.id]).frame(height: 76)
            }
        }
        .padding(16)
    }

    private func card(_ upload: CloudUpload, local: CaptureLibraryItem?) -> some View {
        CloudUploadCard(upload: upload, local: local, layout: layout,
                        selected: cloud.selection == upload.id, deleting: cloud.deletingIDs.contains(upload.id))
            // Selects at once; a second click opens the link.
            .simultaneousGesture(TapGesture().onEnded { cloud.selection = upload.id })
            .onTapGesture(count: 2) { cloud.open(upload) }
            .contextMenu {
                Button("Open Link", systemImage: "arrow.up.right") { cloud.open(upload) }
                Button("Copy Link", systemImage: "link") { cloud.copyLink(upload) }
                if let local {
                    Button("Show in Library", systemImage: "photo.on.rectangle") { cloud.showInLibrary(local) }
                }
                Divider()
                Button("Delete from Cloud…", systemImage: "icloud.slash", role: .destructive) {
                    cloud.pendingDelete = upload
                }
            }
            .accessibilityAction(named: "Open Link") { cloud.open(upload) }
            .accessibilityAction(named: "Copy Link") { cloud.copyLink(upload) }
            .accessibilityAction(named: "Delete from Cloud") { cloud.pendingDelete = upload }
    }
}

/// A Library card for an upload: the same chrome, the capture's own
/// thumbnail when it's still in the Library, else the Worker's.
private struct CloudUploadCard: View {
    let upload: CloudUpload
    let local: CaptureLibraryItem?
    let layout: CaptureLibraryLayout
    let selected: Bool
    let deleting: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    var body: some View {
        Group {
            if layout == .grid {
                VStack(alignment: .leading, spacing: 8) {
                    thumbnail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    labels.padding(.horizontal, 4).padding(.bottom, 4)
                }
            } else {
                HStack(spacing: 14) {
                    thumbnail.frame(width: 88, height: 58)
                    labels
                    Spacer(minLength: 8)
                    Text(local == nil ? "Cloud only" : "In Library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }
            }
        }
        .padding(6)
        .background(
            Color.primary.opacity(selected ? 0.075 : isHovering ? 0.035 : 0.012),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .background(WorkspaceChrome.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(selected ? (contrast == .increased ? 0.65 : 0.28) : 0.08),
                    lineWidth: selected ? 1 : 0.5
                )
        }
        .opacity(deleting ? 0.5 : 1)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(upload.name), \(upload.kindTitle), \(CloudUploadText.subtitle(upload))"
            + (local == nil ? ", cloud only" : ", in Library"))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(upload.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if local != nil, layout == .grid {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary).help("The capture is in your Library")
                }
            }
            Text(CloudUploadText.subtitle(upload)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var thumbnail: some View {
        CloudUploadThumbnail(upload: upload, local: local)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if upload.isVideo, let duration = upload.duration {
                    Label(CloudUploadText.duration(duration), systemImage: "play.fill")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(7)
                }
            }
    }
}

nonisolated enum CloudUploadText {
    static func subtitle(_ upload: CloudUpload) -> String {
        let date = upload.createdAt.formatted(date: .abbreviated, time: .omitted)
        if upload.isVideo, let seconds = upload.duration { return "\(date) · \(duration(seconds))" }
        if let size = upload.size { return "\(date) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))" }
        return date
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let whole = Int(min(seconds.rounded(), Double(Int.max / 2)))
        if whole >= 3600 { return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

private struct CloudUploadThumbnail: View {
    let upload: CloudUpload
    let local: CaptureLibraryItem?
    @State private var image: CGImage?

    var body: some View {
        if let local {
            CaptureLibraryThumbnail(item: local)
        } else {
            GeometryReader { geometry in
                ZStack {
                    Color(nsColor: .quaternaryLabelColor).opacity(0.25)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        Image(systemName: upload.isVideo ? "video" : "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipped()
            .task(id: upload.thumbnailUrl) {
                image = nil
                guard let link = upload.thumbnailUrl, let url = URL(string: link) else { return }
                let result = await CloudThumbnails.image(at: url)
                guard !Task.isCancelled else { return }
                image = result
            }
            .accessibilityHidden(true)
        }
    }
}

/// Posters and screenshots from the Worker's public routes, downsampled like
/// the Library's own thumbnails.
private enum CloudThumbnails {
    // ponytail: screenshots download in full; a Worker thumbnail route if
    // long lists of large screenshots get slow.
    private static let cache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.countLimit = 160
        return cache
    }()

    static func image(at url: URL) async -> CGImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
            ] as CFDictionary)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

struct CloudUploadInspector: View {
    let cloud: CloudLibraryModel

    var body: some View {
        if let upload = cloud.selectedUpload {
            let local = cloud.localItems[upload.id]
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        CloudUploadThumbnail(upload: upload, local: local)
                            .aspectRatio(1.45, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 11))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                            }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(upload.name)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Text(upload.kindTitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("Information")
                        VStack(spacing: 11) {
                            detailRow("Link", value: upload.url)
                            detailRow("Uploaded", value: upload.createdAt.formatted(date: .abbreviated, time: .shortened))
                            if upload.isVideo, let duration = upload.duration {
                                detailRow("Duration", value: CloudUploadText.duration(duration))
                            }
                            if let size = upload.size {
                                detailRow("Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            }
                            if let views = upload.views { detailRow("Views", value: views.formatted()) }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("On This Mac")
                        if let local {
                            detailRow("Capture", value: local.name)
                            Button("Show in Library") { cloud.showInLibrary(local) }
                                .controlSize(.small)
                        } else {
                            Text("The capture is no longer in the Library. Only the cloud copy remains.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 0) {
                    action("Open Link", symbol: "arrow.up.right") { cloud.open(upload) }
                    action("Copy Link", symbol: "link") { cloud.copyLink(upload) }
                    action("Delete from Cloud…", symbol: "icloud.slash") { cloud.pendingDelete = upload }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .disabled(cloud.deletingIDs.contains(upload.id))
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "icloud")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Upload details")
                    .font(.headline)
                Text("Select an upload to see its link\nand whether it’s still in the Library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .frame(minWidth: 40, maxWidth: .infinity)
                .frame(height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(BarButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}
