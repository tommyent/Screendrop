import AppKit
import SwiftUI

/// The Library's Likes page: every like on this Worker's share pages,
/// newest first, mirroring Comments. Likes are anonymous, so each reads
/// "Someone liked …". Unread is kept on this Mac per Worker, and the
/// sidebar badge counts what arrived since the page was last opened. There's
/// no delete: an owner can't remove a like (SPEC-share-v2.md section 9).
@MainActor
@Observable
final class LikesLibraryModel {
    static let shared = LikesLibraryModel()
    /// The Likes page shows in place of the captures.
    private(set) var isShown = false
    var selection: Set<String> = []
    private(set) var likes: [CloudLike] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// The Worker predates GET /api/likes.
    private(set) var isUnavailable = false
    /// Unread when the page was opened, marked with a dot until it's left.
    private(set) var freshIDs: Set<String> = []
    private var watermark: FeedWatermark?
    private var watermarkWorker: String?

    private init() {}

    var unreadCount: Int {
        guard let watermark else { return likes.count }
        return likes.filter { watermark.isUnread($0) }.count
    }

    /// Selected likes in display order.
    var selectedLikes: [CloudLike] { visibleLikes.filter { selection.contains($0.id) } }

    /// Likes matching the Library's search, by upload.
    var visibleLikes: [CloudLike] {
        let library = CaptureLibraryModel.shared
        let query = library.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? likes : likes.filter { $0.uploadName.localizedStandardContains(query) }
        // The feed arrives newest first; Oldest is the only other order that reads as an inbox.
        return library.sortOrder == .oldest ? matching.reversed() : matching
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown { markRead() } else { freshIDs = [] }
    }

    func refresh() {
        guard !isLoading else { return }
        guard CloudUploader.shared.isConfigured else {
            likes = []
            hasLoaded = true
            return
        }
        loadWatermark()
        isLoading = true
        Task {
            defer {
                isLoading = false
                hasLoaded = true
            }
            do {
                likes = try await CloudUploader.shared.listLikes()
                isUnavailable = false
                loadError = nil
            } catch CloudUploadError.likesUnavailable {
                likes = []
                isUnavailable = true
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            selection.formIntersection(likes.map(\.id))
            if isShown { markRead() }
        }
    }

    /// Everything loaded counts as read; what was unread keeps its dot
    /// while the page stays open.
    private func markRead() {
        if let watermark {
            freshIDs.formUnion(likes.filter { watermark.isUnread($0) }.map(\.id))
        } else {
            freshIDs.formUnion(likes.map(\.id))
        }
        watermark = FeedWatermark.reading(likes, after: watermark)
        guard let watermarkWorker, let watermark, let data = try? JSONEncoder().encode(watermark) else { return }
        UserDefaults.standard.set(data, forKey: Self.watermarkKey + watermarkWorker)
    }

    private static let watermarkKey = "cloudLikesRead."

    /// Read state belongs to one Worker; switching Workers starts afresh.
    private func loadWatermark() {
        let worker = CloudUploader.shared.workerBase
        guard worker != watermarkWorker else { return }
        watermarkWorker = worker
        watermark = worker
            .flatMap { UserDefaults.standard.data(forKey: Self.watermarkKey + $0) }
            .flatMap { try? JSONDecoder().decode(FeedWatermark.self, from: $0) }
    }

    func open(_ like: CloudLike) {
        if let url = CloudLikeList.shareLink(for: like) { NSWorkspace.shared.open(url) }
    }

    /// The share links of the liked uploads, each once.
    func copyLinks(_ likes: [CloudLike]) {
        var seen: Set<String> = []
        let links = likes.map(\.upload.shareUrl).filter { seen.insert($0).inserted }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    /// The collection's keys and clicks: a double click opens the share
    /// page, ⌘C copies its link.
    func perform(_ action: CaptureLibraryAction) {
        switch action {
        case .edit: if let like = selectedLikes.first { open(like) }
        case .copy: copyLinks(selectedLikes)
        case .preview, .rename, .export, .reveal, .trash: break
        }
    }

    /// The selection's context menu, also the toolbar's Actions menu.
    func menuItems() -> [LibraryMenuItem] {
        let selected = selectedLikes
        let single = selected.count == 1 ? selected.first : nil
        return [
            LibraryMenuItem(title: "Open on Share Page", isEnabled: single != nil) { if let single { self.open(single) } },
            LibraryMenuItem(title: selected.count > 1 ? "Copy Links" : "Copy Link", isEnabled: !selected.isEmpty) {
                self.copyLinks(selected)
            },
            LibraryMenuItem(title: "Show Upload in Cloud", isEnabled: single != nil) {
                if let single { CloudLibraryModel.shared.showUpload(id: single.uploadId) }
            },
        ]
    }
}

struct LikesLibraryPage: View {
    let likes: LikesLibraryModel

    var body: some View {
        let visible = likes.visibleLikes
        if !CloudUploader.shared.isConfigured {
            ContentUnavailableView {
                Label("Cloud Isn’t Set Up", systemImage: "cloud")
            } description: {
                Text("Add your Worker in Settings to share captures and see their likes here.")
            } actions: {
                Button("Open Cloud Settings") { SettingsWindowController.show(tab: .cloud) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if !likes.hasLoaded {
            ProgressView("Loading Likes…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if likes.isUnavailable {
            ContentUnavailableView {
                Label("Update Your Worker", systemImage: "arrow.up.circle")
            } description: {
                Text("This Worker can’t list likes yet. Update it to see your share pages’ likes here.")
            }
        } else if let error = likes.loadError, likes.likes.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load Likes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { likes.refresh() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if visible.isEmpty {
            let search = CaptureLibraryModel.shared.searchText
            ContentUnavailableView {
                if search.isEmpty {
                    Label("No Likes Yet", systemImage: "heart")
                } else {
                    Label("No Results for “\(search)”", systemImage: "magnifyingglass")
                }
            } description: {
                Text(search.isEmpty
                    ? "Likes people give your share pages appear here."
                    : "Check the spelling or try a new search.")
            }
        } else {
            let uploads = Dictionary(CloudLibraryModel.shared.uploads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let local = CloudLibraryModel.shared.localItems
            CaptureLibraryCollection(
                items: visible, revision: revision(visible, uploads: uploads), layout: .list, cardWidth: 220,
                selection: Binding { likes.selection } set: { likes.selection = $0 },
                isBusy: false, accessibilityLabel: "Likes",
                cell: { [fresh = likes.freshIDs] like, selected, _ in
                    AnyView(LikeRow(like: like, upload: uploads[like.uploadId], local: local[like.uploadId],
                                    selected: selected, fresh: fresh.contains(like.id)))
                },
                menu: { _ in likes.menuItems() },
                onAction: likes.perform
            )
        }
    }

    /// Changes whenever a row would draw differently, so the collection reloads.
    private func revision(_ visible: [CloudLike], uploads: [String: CloudUpload]) -> Int {
        var hasher = Hasher()
        hasher.combine(visible)
        hasher.combine(likes.freshIDs)
        hasher.combine(Set(uploads.keys))
        hasher.combine(CaptureLibraryModel.shared.contentRevision)
        return hasher.finalize()
    }
}

/// A like as an inbox row: the upload's thumbnail, "Someone liked" and the
/// upload's name, and when.
private struct LikeRow: View {
    let like: CloudLike
    let upload: CloudUpload?
    let local: CaptureLibraryItem?
    let selected: Bool
    let fresh: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.blue)
                .frame(width: 7, height: 7)
                .opacity(fresh ? 1 : 0)
                .accessibilityHidden(true)
            CloudFeedThumbnail(isVideo: like.isVideo, upload: upload, local: local)
                .frame(width: 88, height: 58)
                .clipShape(.rect(cornerRadius: DS.Radius.m))
            VStack(alignment: .leading, spacing: 3) {
                Text("Someone liked \(Text(like.uploadName).fontWeight(.semibold))")
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(like.createdAt, format: .relative(presentation: .named))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(6)
        .background(
            Color.primary.opacity(selected ? 0.075 : isHovering ? 0.035 : 0.012),
            in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        )
        .background(WorkspaceChrome.background, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            LibraryCardBorder(selected: selected)
        }
        .onHover { isHovering = $0 }
        // Cells are reused for other likes.
        .onChange(of: like.id) { _, _ in isHovering = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((fresh ? "New. " : "") + "Someone liked \(like.uploadName), "
            + like.createdAt.formatted(.relative(presentation: .named)))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "Open on Share Page") { LikesLibraryModel.shared.open(like) }
    }
}

struct LikeInspector: View {
    let likes: LikesLibraryModel

    var body: some View {
        let selected = likes.selectedLikes
        if selected.count > 1 {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionVerticalPadding) {
                Text("\(selected.count) likes selected").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.vertical, InspectorMetrics.sectionVerticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 0) {
                    action("Copy Links", symbol: "link") { likes.copyLinks(selected) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .modifier(LibraryInspectorBarSurface())
            }
        } else if let like = selected.first {
            single(like)
        } else {
            LibraryInspectorPlaceholder(
                symbol: "heart", title: "Like details",
                message: "Select a like to see\nthe upload it’s on."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func single(_ like: CloudLike) -> some View {
        let cloud = CloudLibraryModel.shared
        let upload = cloud.uploads.first { $0.id == like.uploadId }
        return ScrollView {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionVerticalPadding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Someone liked this").font(.system(size: 15, weight: .semibold))
                    Text(like.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(InspectorControlPalette.label)
                }
                Divider()
                VStack(alignment: .leading, spacing: InspectorMetrics.headerSpacing) {
                    Text("Upload").font(.inspectorSectionHeader).foregroundStyle(InspectorControlPalette.label)
                    CloudFeedThumbnail(isVideo: like.isVideo, upload: upload, local: cloud.localItems[like.uploadId])
                        .aspectRatio(1.45, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 11))
                    Text(like.uploadName).font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.middle)
                    Text(like.upload.shareUrl).font(.system(size: 12)).foregroundStyle(InspectorControlPalette.label).textSelection(.enabled)
                    if let expiresAt = like.upload.expiresAt {
                        Text(CloudUploadText.expiryDate(expiresAt)).font(.system(size: 12)).foregroundStyle(InspectorControlPalette.label)
                    }
                }
            }
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.vertical, InspectorMetrics.sectionVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                action("Open on Share Page", symbol: "arrow.up.right") { likes.open(like) }
                action("Copy Link", symbol: "link") { likes.copyLinks([like]) }
                action("Show Upload in Cloud", symbol: "cloud") { cloud.showUpload(id: like.uploadId) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .modifier(LibraryInspectorBarSurface())
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
}
