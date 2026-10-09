import AppKit
import SwiftUI

/// The Library's Comments page: every comment left on this Worker's share
/// pages, newest first. Unread is kept on this Mac per Worker; the sidebar
/// badge counts what arrived since the page was last opened.
@MainActor
@Observable
final class CommentsLibraryModel {
    static let shared = CommentsLibraryModel()
    /// The Comments page shows in place of the captures.
    private(set) var isShown = false
    var selection: Set<String> = []
    /// Waiting for the Delete Comment confirmation.
    var pendingDelete: [CloudComment] = []
    private(set) var comments: [CloudComment] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// The Worker predates GET /api/comments.
    private(set) var isUnavailable = false
    private(set) var deletingIDs: Set<String> = []
    /// Unread when the page was opened, marked with a dot until it's left.
    private(set) var freshIDs: Set<String> = []
    private var watermark: CommentWatermark?
    private var watermarkWorker: String?

    private init() {}

    var unreadCount: Int {
        guard let watermark else { return comments.count }
        return comments.filter(watermark.isUnread).count
    }

    /// Selected comments in display order.
    var selectedComments: [CloudComment] { visibleComments.filter { selection.contains($0.id) } }
    var isBusy: Bool { !deletingIDs.isEmpty }

    /// Comments matching the Library's search: text, author or upload.
    var visibleComments: [CloudComment] {
        let library = CaptureLibraryModel.shared
        let query = library.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? comments : comments.filter {
            $0.text.localizedStandardContains(query) || $0.authorName.localizedStandardContains(query)
                || $0.uploadName.localizedStandardContains(query)
        }
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
            comments = []
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
                comments = try await CloudUploader.shared.listComments()
                isUnavailable = false
                loadError = nil
            } catch CloudUploadError.commentsUnavailable {
                comments = []
                isUnavailable = true
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            selection.formIntersection(comments.map(\.id))
            if isShown { markRead() }
        }
    }

    /// Everything loaded counts as read; what was unread keeps its dot
    /// while the page stays open.
    private func markRead() {
        if let watermark {
            freshIDs.formUnion(comments.filter(watermark.isUnread).map(\.id))
        } else {
            freshIDs.formUnion(comments.map(\.id))
        }
        watermark = CommentWatermark.reading(comments, after: watermark)
        guard let watermarkWorker, let watermark, let data = try? JSONEncoder().encode(watermark) else { return }
        UserDefaults.standard.set(data, forKey: Self.watermarkKey + watermarkWorker)
    }

    private static let watermarkKey = "cloudCommentsRead."

    /// Read state belongs to one Worker; switching Workers starts afresh.
    private func loadWatermark() {
        let worker = CloudUploader.shared.workerBase
        guard worker != watermarkWorker else { return }
        watermarkWorker = worker
        watermark = worker
            .flatMap { UserDefaults.standard.data(forKey: Self.watermarkKey + $0) }
            .flatMap { try? JSONDecoder().decode(CommentWatermark.self, from: $0) }
    }

    func open(_ comment: CloudComment) {
        if let url = CloudCommentList.shareLink(for: comment) { NSWorkspace.shared.open(url) }
    }

    func copyText(_ comments: [CloudComment]) {
        guard !comments.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(comments.map(\.text).joined(separator: "\n\n"), forType: .string)
    }

    /// The collection's keys and clicks: a double click opens the share
    /// page at the comment, ⌘C copies, ⌘⌫ asks to delete.
    func perform(_ action: CaptureLibraryAction) {
        switch action {
        case .edit: if let comment = selectedComments.first { open(comment) }
        case .copy: copyText(selectedComments)
        case .trash: pendingDelete = selectedComments
        case .preview, .rename, .export, .reveal: break
        }
    }

    /// The selection's context menu, also the toolbar's Actions menu.
    func menuItems() -> [LibraryMenuItem] {
        let selected = selectedComments
        let single = selected.count == 1 ? selected.first : nil
        return [
            LibraryMenuItem(title: "Open on Share Page", isEnabled: single != nil) { if let single { self.open(single) } },
            LibraryMenuItem(title: "Copy Text", isEnabled: !selected.isEmpty) { self.copyText(selected) },
            LibraryMenuItem(title: "Show Upload in Cloud", isEnabled: single != nil) {
                if let single { CloudLibraryModel.shared.showUpload(id: single.uploadId) }
            },
            LibraryMenuItem(title: selected.count > 1 ? "Delete Comments…" : "Delete Comment…",
                            isEnabled: !selected.isEmpty && !isBusy, startsGroup: true) {
                self.pendingDelete = selected
            },
        ]
    }

    /// Deletes the confirmed comments one at a time with the owner's route,
    /// then reloads from the start, since offsets shift under deletions.
    func deletePending() {
        let targets = pendingDelete.filter { !deletingIDs.contains($0.id) }
        pendingDelete = []
        guard !targets.isEmpty else { return }
        deletingIDs.formUnion(targets.map(\.id))
        Task {
            var failures: [String] = []
            for comment in targets {
                do {
                    try await CloudUploader.shared.deleteComment(uploadID: comment.uploadId, commentID: comment.id)
                    comments.removeAll { $0.id == comment.id }
                    selection.remove(comment.id)
                } catch {
                    failures.append("\(comment.authorName): \(error.localizedDescription)")
                }
                deletingIDs.remove(comment.id)
            }
            if !failures.isEmpty { CaptureLibraryModel.shared.errorMessage = failures.joined(separator: "\n") }
            refresh()
        }
    }
}

struct CommentsLibraryPage: View {
    let comments: CommentsLibraryModel

    var body: some View {
        let visible = comments.visibleComments
        Group {
            if !CloudUploader.shared.isConfigured {
                ContentUnavailableView {
                    Label("Cloud Isn’t Set Up", systemImage: "cloud")
                } description: {
                    Text("Add your Worker in Settings to share captures and read their comments here.")
                } actions: {
                    Button("Open Cloud Settings") { SettingsWindowController.show(tab: .cloud) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else if !comments.hasLoaded {
                ProgressView("Loading Comments…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if comments.isUnavailable {
                ContentUnavailableView {
                    Label("Update Your Worker", systemImage: "arrow.up.circle")
                } description: {
                    Text("This Worker can’t list comments yet. Update it to read your share pages’ comments here.")
                }
            } else if let error = comments.loadError, comments.comments.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Comments", systemImage: "exclamationmark.bubble")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { comments.refresh() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else if visible.isEmpty {
                let search = CaptureLibraryModel.shared.searchText
                ContentUnavailableView {
                    if search.isEmpty {
                        Label("No Comments Yet", systemImage: "bubble.left.and.bubble.right")
                    } else {
                        Label("No Results for “\(search)”", systemImage: "magnifyingglass")
                    }
                } description: {
                    Text(search.isEmpty
                        ? "Comments people leave on your share pages appear here."
                        : "Check the spelling or try a new search.")
                }
            } else {
                let uploads = Dictionary(CloudLibraryModel.shared.uploads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let local = CloudLibraryModel.shared.localItems
                CaptureLibraryCollection(
                    items: visible, revision: revision(visible, uploads: uploads), layout: .list, cardWidth: 220,
                    selection: Binding { comments.selection } set: { comments.selection = $0 },
                    isBusy: comments.isBusy, accessibilityLabel: "Comments",
                    cell: { [fresh = comments.freshIDs, deleting = comments.deletingIDs] comment, selected, _ in
                        AnyView(CommentRow(comment: comment, upload: uploads[comment.uploadId], local: local[comment.uploadId],
                                           selected: selected, fresh: fresh.contains(comment.id),
                                           deleting: deleting.contains(comment.id)))
                    },
                    menu: { _ in comments.menuItems() },
                    onAction: comments.perform
                )
            }
        }
        .alert(comments.pendingDelete.count > 1 ? "Delete \(comments.pendingDelete.count) comments?" : "Delete comment?",
               isPresented: Binding(get: { !comments.pendingDelete.isEmpty }, set: { if !$0 { comments.pendingDelete = [] } })) {
            Button("Delete", role: .destructive) { comments.deletePending() }
            Button("Cancel", role: .cancel) { comments.pendingDelete = [] }
        } message: {
            Text(comments.pendingDelete.count > 1
                ? "They’re removed from their share pages for everyone."
                : "It’s removed from its share page for everyone.")
        }
    }

    /// Changes whenever a row would draw differently, so the collection reloads.
    private func revision(_ visible: [CloudComment], uploads: [String: CloudUpload]) -> Int {
        var hasher = Hasher()
        hasher.combine(visible)
        hasher.combine(comments.freshIDs)
        hasher.combine(comments.deletingIDs)
        hasher.combine(Set(uploads.keys))
        hasher.combine(CaptureLibraryModel.shared.contentRevision)
        return hasher.finalize()
    }
}

/// A comment as an inbox row: the upload's thumbnail, who wrote it and
/// when, the video moment, two lines of text and the upload's name.
private struct CommentRow: View {
    let comment: CloudComment
    /// The upload as the Cloud page has it, for its thumbnail; nil until loaded.
    let upload: CloudUpload?
    let local: CaptureLibraryItem?
    let selected: Bool
    let fresh: Bool
    let deleting: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.blue)
                .frame(width: 7, height: 7)
                .opacity(fresh ? 1 : 0)
                .accessibilityHidden(true)
            CommentUploadThumbnail(comment: comment, upload: upload, local: local)
                .frame(width: 88, height: 58)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    CommentAuthorAvatar(comment: comment, size: 16)
                    Text(comment.authorName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(comment.createdAt, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let moment = CommentText.moment(comment) {
                        Text("at \(moment)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.system(size: 12))
                Text(comment.text).font(.system(size: 12)).lineLimit(2)
                Text("on \(comment.uploadName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .opacity(deleting ? 0.5 : 1)
        .onHover { isHovering = $0 }
        // Cells are reused for other comments.
        .onChange(of: comment.id) { _, _ in isHovering = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((fresh ? "New. " : "") + "\(comment.authorName), "
            + comment.createdAt.formatted(.relative(presentation: .named))
            + (CommentText.moment(comment).map { ", at \($0)" } ?? "") + ": \(comment.text). On \(comment.uploadName)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "Open on Share Page") { CommentsLibraryModel.shared.open(comment) }
        .accessibilityAction(named: "Delete Comment") { CommentsLibraryModel.shared.pendingDelete = [comment] }
    }
}

/// The upload's thumbnail from the Cloud page, or a placeholder while that
/// upload isn't loaded there.
private struct CommentUploadThumbnail: View {
    let comment: CloudComment
    let upload: CloudUpload?
    let local: CaptureLibraryItem?

    var body: some View {
        if let upload {
            CloudUploadThumbnail(upload: upload, local: local)
        } else {
            ZStack {
                Color(nsColor: .quaternaryLabelColor).opacity(0.25)
                Image(systemName: comment.isVideo ? "video" : "photo").foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)
        }
    }
}

/// A signed-in commenter's picture, or their initials. Anonymous comments
/// have no picture, so most rows show initials and load nothing.
private struct CommentAuthorAvatar: View {
    let comment: CloudComment
    let size: CGFloat

    var body: some View {
        Group {
            if let link = comment.authorAvatar, let url = URL(string: link), url.scheme == "https" {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initials
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.25))
            Text(CommentText.initials(comment.authorName))
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

nonisolated enum CommentText {
    /// "0:41" for a comment left at a moment in a video; nil otherwise.
    /// Whole seconds rounded down, the moment its link opens at (?t=).
    static func moment(_ comment: CloudComment) -> String? {
        guard comment.isVideo, let seconds = comment.timestamp, seconds.isFinite, seconds >= 0 else { return nil }
        return CloudUploadText.duration(seconds.rounded(.down))
    }

    /// Up to two initials, "?" without any letters.
    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

struct CommentInspector: View {
    let comments: CommentsLibraryModel

    var body: some View {
        let selected = comments.selectedComments
        if selected.count > 1 {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionVerticalPadding) {
                Text("\(selected.count) comments selected").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.vertical, InspectorMetrics.sectionVerticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 0) {
                    action("Copy Text", symbol: "doc.on.doc") { comments.copyText(selected) }
                    action("Delete Comments…", symbol: "trash") { comments.pendingDelete = selected }
                        .disabled(comments.isBusy)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        } else if let comment = selected.first {
            single(comment)
        } else {
            LibraryInspectorPlaceholder(
                symbol: "bubble.left.and.bubble.right", title: "Comment details",
                message: "Select a comment to read it in full\nand see the upload it’s on."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func single(_ comment: CloudComment) -> some View {
        let cloud = CloudLibraryModel.shared
        let upload = cloud.uploads.first { $0.id == comment.uploadId }
        return ScrollView {
            VStack(alignment: .leading, spacing: InspectorMetrics.sectionVerticalPadding) {
                HStack(spacing: 10) {
                    CommentAuthorAvatar(comment: comment, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.authorName).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                        Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened)
                            + (CommentText.moment(comment).map { " · at \($0)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(comment.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                VStack(alignment: .leading, spacing: InspectorMetrics.headerSpacing) {
                    Text("Upload").font(.inspectorSectionHeader).foregroundStyle(InspectorControlPalette.label)
                    CommentUploadThumbnail(comment: comment, upload: upload, local: cloud.localItems[comment.uploadId])
                        .aspectRatio(1.45, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 11))
                    Text(comment.uploadName).font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(.middle)
                    Text(comment.upload.shareUrl).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let expiresAt = comment.upload.expiresAt {
                        Text(CloudUploadText.expiryDate(expiresAt)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.vertical, InspectorMetrics.sectionVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                action("Open on Share Page", symbol: "arrow.up.right") { comments.open(comment) }
                action("Copy Text", symbol: "doc.on.doc") { comments.copyText([comment]) }
                action("Show Upload in Cloud", symbol: "cloud") { cloud.showUpload(id: comment.uploadId) }
                action("Delete Comment…", symbol: "trash") { comments.pendingDelete = [comment] }
                    .disabled(comments.deletingIDs.contains(comment.id))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
