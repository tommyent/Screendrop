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
    var selection: Set<String> = []
    /// Waiting for the Delete from Cloud confirmation.
    var pendingDelete: [CloudUpload] = []
    private(set) var uploads: [CloudUpload] = []
    /// Listed from History because the Worker can't list uploads.
    private(set) var isHistoryFallback = false
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var deletingIDs: Set<String> = []
    /// Uploads whose share settings are being changed.
    private(set) var savingIDs: Set<String> = []
    /// Quick Look's download, while it runs.
    private(set) var previewFetch: PreviewFetch?
    private var previewTask: Task<Void, Never>?
    /// Esc stops the download while it runs.
    private var escapeMonitor: Any?

    struct PreviewFetch {
        let id = UUID()
        /// The uploads being fetched, in the order Quick Look will show them.
        let uploadIDs: [String]
        var index = 0
        var fraction = 0.0
        var count: Int { uploadIDs.count }
        var title: String { count == 1 ? "Downloading for Quick Look…" : "Downloading \(index + 1) of \(count) for Quick Look…" }
        var total: Double { (Double(index) + fraction) / Double(count) }
    }

    private init() {}

    /// The selection in display order.
    var selectedUploads: [CloudUpload] { visibleUploads.filter { selection.contains($0.id) } }
    var isBusy: Bool { !deletingIDs.isEmpty }

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
            selection.formIntersection(uploads.map(\.id))
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

    func copyLinks(_ uploads: [CloudUpload]) {
        guard !uploads.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uploads.map(\.url).joined(separator: "\n"), forType: .string)
    }

    /// The collection's keys and clicks. Uploads are final, so they have no
    /// editor: a double click (`.edit`) opens the share page, with its
    /// comments, as the Library's link does.
    func perform(_ action: CaptureLibraryAction) {
        switch action {
        case .preview: quickLook()
        case .edit: if let upload = selectedUploads.first { open(upload) }
        case .copy: copyLinks(selectedUploads)
        case .trash: pendingDelete = selectedUploads
        case .rename, .export, .reveal: break
        }
    }

    /// The selection's context menu, also the toolbar's Actions menu.
    func menuItems() -> [LibraryMenuItem] {
        let selected = selectedUploads
        let single = selected.count == 1 ? selected.first : nil
        let local = single.flatMap { localItems[$0.id] }
        return [
            LibraryMenuItem(title: "Quick Look", isEnabled: !selected.isEmpty) { self.quickLook(toggling: false) },
            LibraryMenuItem(title: "Open Link", isEnabled: single != nil) { if let single { self.open(single) } },
            LibraryMenuItem(title: selected.count > 1 ? "Copy Links" : "Copy Link", isEnabled: !selected.isEmpty) {
                self.copyLinks(selected)
            },
            LibraryMenuItem(title: "Show in Library", isEnabled: local != nil) { if let local { self.showInLibrary(local) } },
            LibraryMenuItem(title: "Delete from Cloud…", isEnabled: !selected.isEmpty && !isBusy, startsGroup: true) {
                self.pendingDelete = selected
            },
        ]
    }

    /// Downloads the selected uploads' full files from the Worker's public
    /// routes, then opens Quick Look on them in display order. Asked again
    /// while it downloads or shows, it stops, like Space in Finder.
    func quickLook(toggling: Bool = true) {
        if toggling, previewTask != nil { cancelPreview(); return }
        if toggling, QuickLookPreviewPresenter.isShown { QuickLookPreviewPresenter.dismiss(); return }
        let targets = selectedUploads
        guard !targets.isEmpty else { return }
        cancelPreview()
        let fetch = PreviewFetch(uploadIDs: targets.map(\.id))
        let fetchID = fetch.id
        previewFetch = fetch
        let window = NSApp.keyWindow
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard event.keyCode == 53, event.window === window else { return event }
            self?.cancelPreview()
            return nil
        }
        let kept = Set(fetch.uploadIDs)
        let owner = CloudUploader.shared.ownerAccess
        previewTask = Task {
            defer { if previewFetch?.id == fetchID { cancelPreview() } }
            var files: [URL] = []
            var failures: [String] = []
            for (index, upload) in targets.enumerated() {
                updatePreview(fetchID, index: index, fraction: 0)
                do {
                    files.append(try await CloudPreviewCache.shared.file(for: upload, keeping: kept, owner: owner) { fraction in
                        Task { @MainActor in self.updatePreview(fetchID, index: index, fraction: fraction) }
                    })
                } catch {
                    if Task.isCancelled { return }
                    failures.append("\(upload.name): \(error.localizedDescription)")
                }
            }
            if Task.isCancelled { return }
            QuickLookPreviewPresenter.show(urls: files)
            if !failures.isEmpty {
                CaptureLibraryModel.shared.errorMessage = "Couldn’t download for Quick Look:\n" + failures.joined(separator: "\n")
            }
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewFetch = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func updatePreview(_ id: UUID, index: Int, fraction: Double) {
        guard let fetch = previewFetch, fetch.id == id, index >= fetch.index else { return }
        previewFetch?.index = index
        previewFetch?.fraction = fraction
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

    /// Changes an upload's expiry (counted from now; `.never` clears it),
    /// anonymous comments or password (`.some(nil)` removes it) on the
    /// Worker, then shows what it answered.
    func updateSettings(_ upload: CloudUpload, expiry: CloudExpiry? = nil, allowAnonymousComments: Bool? = nil,
                        password: String?? = nil) {
        guard savingIDs.insert(upload.id).inserted else { return }
        Task {
            defer { savingIDs.remove(upload.id) }
            do {
                let updated = try await CloudUploader.shared.updateUpload(
                    id: upload.id, expiresAt: expiry.map { $0.date() }, allowAnonymousComments: allowAnonymousComments,
                    password: password
                )
                if var updated, let index = uploads.firstIndex(where: { $0.id == upload.id }) {
                    // Only the list counts comments; keep the count PATCH leaves out.
                    updated.commentCount = updated.commentCount ?? uploads[index].commentCount
                    uploads[index] = updated
                } else {
                    refresh()
                }
            } catch {
                CaptureLibraryModel.shared.errorMessage = error.localizedDescription
            }
        }
    }

    /// Deletes the confirmed uploads one at a time with the inspector's
    /// Delete from Cloud call, and like it, clears each link from the
    /// capture's History entries.
    func deletePending() {
        let targets = pendingDelete.filter { !deletingIDs.contains($0.id) }
        pendingDelete = []
        guard !targets.isEmpty else { return }
        QuickLookPreviewPresenter.dismiss()
        deletingIDs.formUnion(targets.map(\.id))
        Task {
            var failures: [String] = []
            for upload in targets {
                do {
                    try await CloudUploader.shared.deleteFromCloud(uploadID: upload.id)
                    let history = ScreenshotHistoryStore.shared
                    for item in history.items where CloudUploadList.uploadID(of: item.cloudURL) == upload.id {
                        history.setLibraryCloudURL(id: item.id, cloudURL: nil)
                    }
                    uploads.removeAll { $0.id == upload.id }
                    selection.remove(upload.id)
                    CloudPreviewCache.shared.remove(upload.id)
                } catch {
                    failures.append("\(upload.name): \(error.localizedDescription)")
                }
                deletingIDs.remove(upload.id)
            }
            if !failures.isEmpty { CaptureLibraryModel.shared.errorMessage = failures.joined(separator: "\n") }
        }
    }
}

struct CloudLibraryPage: View {
    let cloud: CloudLibraryModel
    let layout: CaptureLibraryLayout
    let cardWidth: CGFloat

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
                // The Library's own collection, so uploads select, open and
                // delete as captures do.
                CaptureLibraryCollection(
                    items: uploads, revision: revision(uploads, local: local), layout: layout, cardWidth: cardWidth,
                    selection: Binding { cloud.selection } set: { cloud.selection = $0 },
                    isBusy: cloud.isBusy, accessibilityLabel: "Uploads",
                    cell: { [layout, deleting = cloud.deletingIDs] upload, selected, _ in
                        AnyView(CloudUploadCard(upload: upload, local: local[upload.id], layout: layout,
                                                selected: selected, deleting: deleting.contains(upload.id)))
                    },
                    menu: { _ in cloud.menuItems() },
                    onAction: cloud.perform
                )
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
        .alert(deleteTitle, isPresented: Binding(
            get: { !cloud.pendingDelete.isEmpty }, set: { if !$0 { cloud.pendingDelete = [] } }
        )) {
            Button("Delete", role: .destructive) { cloud.deletePending() }
            Button("Cancel", role: .cancel) { cloud.pendingDelete = [] }
        } message: {
            Text(deleteMessage(local: local))
        }
    }

    private var deleteTitle: String {
        let count = cloud.pendingDelete.count
        return count > 1 ? "Delete \(count) uploads from cloud?" : "Delete from cloud?"
    }

    private func deleteMessage(local: [String: CaptureLibraryItem]) -> String {
        let targets = cloud.pendingDelete
        let anyLocal = targets.contains { local[$0.id] != nil }
        if targets.count > 1 {
            return "This permanently removes \(targets.count) cloud copies and breaks their share links."
                + (anyLocal ? " Captures still in your Library stay there." : "")
        }
        return "This permanently removes the cloud copy and breaks its share link."
            + (anyLocal ? " Your local capture stays in the Library." : "")
    }

    /// Changes whenever a card would draw differently, so the collection reloads.
    private func revision(_ uploads: [CloudUpload], local: [String: CaptureLibraryItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(uploads)
        hasher.combine(Set(local.keys))
        hasher.combine(CaptureLibraryModel.shared.contentRevision)
        hasher.combine(cloud.deletingIDs)
        return hasher.finalize()
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
                    Text([CloudUploadText.comments(upload.commentCount), upload.hasPassword == true ? "Password" : nil,
                          CloudUploadText.expiry(upload.expiresAt), local == nil ? "Cloud only" : "In Library"]
                        .compactMap(\.self).joined(separator: " · "))
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
        .onHover { isHovering = $0 }
        // Cells are reused for other uploads.
        .onChange(of: upload.id) { _, _ in isHovering = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(upload.name), \(upload.kindTitle), \(CloudUploadText.subtitle(upload))"
            + (CloudUploadText.comments(upload.commentCount).map { ", \($0)" } ?? "")
            + (upload.hasPassword == true ? ", password protected" : "")
            + (CloudUploadText.expiry(upload.expiresAt).map { ", \($0)" } ?? "")
            + (local == nil ? ", cloud only" : ", in Library"))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "Quick Look") { act { $0.quickLook(toggling: false) } }
        .accessibilityAction(named: "Open Link") { CloudLibraryModel.shared.open(upload) }
        .accessibilityAction(named: "Copy Link") { CloudLibraryModel.shared.copyLinks([upload]) }
        .accessibilityAction(named: "Delete from Cloud") { CloudLibraryModel.shared.pendingDelete = [upload] }
    }

    /// Selects just this upload, then acts on the selection.
    private func act(_ action: (CloudLibraryModel) -> Void) {
        let cloud = CloudLibraryModel.shared
        cloud.selection = [upload.id]
        action(cloud)
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
            .overlay { CloudFetchOverlay(uploadID: upload.id) }
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            // Bottom left: free on every card, so it never meets the pills above or the duration.
            .overlay(alignment: .bottomLeading) {
                if layout == .grid, let count = upload.commentCount, count > 0 {
                    Label(count.formatted(), systemImage: "bubble.left.fill")
                        .modifier(CloudCardPill(background: .black.opacity(0.65)))
                        .padding(7)
                        .help(CloudUploadText.comments(count) ?? "")
                }
            }
            .overlay(alignment: .topLeading) {
                // The list says these in words beside the thumbnail instead.
                // The duration pill's style, so they read on any thumbnail.
                if layout == .grid, upload.hasPassword == true || upload.expiresAt != nil {
                    HStack(spacing: 4) {
                        if upload.hasPassword == true {
                            Image(systemName: "lock.fill")
                                .modifier(CloudCardPill(background: .black.opacity(0.65)))
                                .help("Password protected")
                        }
                        if let expiresAt = upload.expiresAt {
                            Label(CloudUploadText.expiryShort(expiresAt), systemImage: "hourglass")
                                .modifier(CloudCardPill(background: expiresAt <= .now ? .red.opacity(0.85) : .black.opacity(0.65)))
                                .help(CloudUploadText.expiryDate(expiresAt))
                        }
                    }
                    .padding(7)
                }
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

/// Over a thumbnail while Quick Look downloads that upload: a ring with the
/// percentage, or a spinner until the size is known, and "Waiting" for the
/// selection's later uploads. It watches the model itself, so the
/// collection doesn't reload for every step.
private struct CloudFetchOverlay: View {
    let uploadID: String

    var body: some View {
        if let fetch = CloudLibraryModel.shared.previewFetch,
           let position = fetch.uploadIDs.firstIndex(of: uploadID), position >= fetch.index {
            ZStack {
                Color.black.opacity(0.3)
                // The duration pill's dark style, so it reads on light and dark thumbnails alike.
                VStack(spacing: 7) {
                    if position > fetch.index {
                        Text("Waiting")
                    } else if fetch.fraction > 0 {
                        ProgressView(value: fetch.fraction).progressViewStyle(.circular)
                        Text(fetch.fraction, format: .percent.precision(.fractionLength(0)))
                    } else {
                        ProgressView()
                        Text("Downloading")
                    }
                }
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .tint(.white)
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(position > fetch.index ? "Waiting to download" : "Downloading for Quick Look")
            .help("Downloading for Quick Look. Press Esc to stop.")
        }
    }
}

/// Sets or changes an upload's password. The field never shows the current
/// one: the Worker keeps only a hash.
private struct CloudPasswordPopover: View {
    let isChange: Bool
    let onSave: (String) -> Void
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isChange ? "Change Password" : "Set Password").font(.headline)
            SecureField("Password", text: $password, prompt: Text("New password"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Text(isChange
                ? "Visitors who unlocked the link need the new password."
                : "Visitors need it to open the link. Share it separately.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!CloudUploadList.isValidPassword(password))
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

/// A small white-on-dark label over a card's thumbnail, like the duration's.
private struct CloudCardPill: ViewModifier {
    let background: Color

    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(background, in: Capsule())
    }
}

nonisolated enum CloudUploadText {
    static func subtitle(_ upload: CloudUpload) -> String {
        let date = upload.createdAt.formatted(date: .abbreviated, time: .omitted)
        if upload.isVideo, let seconds = upload.duration { return "\(date) · \(duration(seconds))" }
        if let size = upload.size { return "\(date) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))" }
        return date
    }

    /// "Expires in 3 days" or "Expired"; nil for a link that never expires.
    static func expiry(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        return date <= now ? "Expired" : "Expires " + date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
    }

    /// "1 comment", "3 comments"; nil when there are none or the Worker doesn't count them.
    static func comments(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1 ? "1 comment" : "\(count.formatted()) comments"
    }

    /// "in 3 days", "Expired" or "Never".
    static func expiryShort(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Never" }
        return date <= now ? "Expired" : date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
    }

    /// "Expires Oct 11, 2026 at 4:40 PM", or "Expired …" once it has passed.
    static func expiryDate(_ date: Date, now: Date = .now) -> String {
        (date <= now ? "Expired " : "Expires ") + date.formatted(date: .abbreviated, time: .shortened)
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
                // Locked uploads' posters and images need the owner's token.
                let result = await CloudThumbnails.image(at: url, owner: upload.hasPassword == true ? CloudUploader.shared.ownerAccess : nil)
                guard !Task.isCancelled else { return }
                image = result
            }
            .accessibilityHidden(true)
        }
    }
}

/// Posters and screenshots from the Worker's media routes, downsampled like
/// the Library's own thumbnails.
private enum CloudThumbnails {
    // ponytail: screenshots download in full; a Worker thumbnail route if
    // long lists of large screenshots get slow.
    private static let cache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.countLimit = 160
        return cache
    }()

    static func image(at url: URL, owner: (workerBase: String, token: String)?) async -> CGImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        let request = CloudUploadList.mediaRequest(url, workerBase: owner?.workerBase, token: owner?.token)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
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
    /// The upload whose password is being set or changed.
    @State private var passwordTarget: CloudUpload?
    @State private var pendingPasswordRemoval: CloudUpload?

    var body: some View {
        let selected = cloud.selectedUploads
        if selected.count > 1 {
            multiple(selected)
        } else if let upload = selected.first {
            let local = cloud.localItems[upload.id]
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        Button { cloud.quickLook(toggling: false) } label: {
                            CloudUploadThumbnail(upload: upload, local: local)
                                .overlay { CloudFetchOverlay(uploadID: upload.id) }
                                .aspectRatio(1.45, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 11))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: upload.isVideo ? "play.fill" : "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(.black.opacity(0.55), in: Circle())
                                        .padding(10)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Quick Look \(upload.name)")
                        .help("Open a large preview")
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
                            if let comments = upload.commentCount { detailRow("Comments", value: comments.formatted()) }
                        }
                    }
                    Divider()
                    sharing(upload)
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
                    action("Copy Link", symbol: "link") { cloud.copyLinks([upload]) }
                    action("Delete from Cloud…", symbol: "icloud.slash") { cloud.pendingDelete = [upload] }
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

    /// The link's expiry and anonymous comments, changed on the Worker.
    private func sharing(_ upload: CloudUpload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Sharing")
            if upload.supportsShareSettings {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Expires")
                    Spacer(minLength: 0)
                    Menu(CloudUploadText.expiryShort(upload.expiresAt)) {
                        ForEach(CloudExpiry.allCases) { expiry in
                            Button(expiry == .never ? "Never" : "In \(expiry.title)") {
                                cloud.updateSettings(upload, expiry: expiry)
                            }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(upload.expiresAt.map { CloudUploadText.expiryDate($0) } ?? "The link never expires")
                }
                HStack(spacing: 12) {
                    Text("Anonymous comments")
                    Spacer(minLength: 0)
                    Toggle("Anonymous comments", isOn: Binding(
                        get: { upload.allowAnonymousComments ?? true },
                        set: { cloud.updateSettings(upload, allowAnonymousComments: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .disabled(upload.socialEnabled == false)
                .help("Visitors can comment without signing in")
                if upload.socialEnabled == false {
                    Text("Comments are off for this upload.").foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("Password")
                    Spacer(minLength: 0)
                    if upload.hasPassword == true {
                        Button("Change…") { passwordTarget = upload }
                        Button("Remove") { pendingPasswordRemoval = upload }
                    } else {
                        Button("Set…") { passwordTarget = upload }
                    }
                }
                .buttonStyle(.borderless)
                .popover(item: $passwordTarget, arrowEdge: .leading) { target in
                    CloudPasswordPopover(isChange: target.hasPassword == true) { password in
                        cloud.updateSettings(target, password: .some(password))
                    }
                }
            } else {
                Text("Update your Worker to set an expiry and allow anonymous comments here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .disabled(cloud.savingIDs.contains(upload.id))
        .alert("Remove the password?", isPresented: Binding(
            get: { pendingPasswordRemoval != nil }, set: { if !$0 { pendingPasswordRemoval = nil } }
        ), presenting: pendingPasswordRemoval) { target in
            Button("Remove", role: .destructive) {
                cloud.updateSettings(target, password: .some(nil))
                pendingPasswordRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingPasswordRemoval = nil }
        } message: { _ in
            Text("Anyone with the link will be able to open it.")
        }
    }

    private func multiple(_ uploads: [CloudUpload]) -> some View {
        let local = cloud.localItems
        let sizes = uploads.compactMap(\.size)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("\(uploads.count) uploads selected")
                    .font(.system(size: 16, weight: .semibold))
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Selection")
                    VStack(spacing: 11) {
                        detailRow("Screenshots", value: "\(uploads.filter { !$0.isVideo }.count)")
                        detailRow("Recordings", value: "\(uploads.filter(\.isVideo).count)")
                        detailRow("Cloud only", value: "\(uploads.filter { local[$0.id] == nil }.count)")
                        if sizes.count == uploads.count {
                            detailRow("Size", value: ByteCountFormatter.string(fromByteCount: Int64(sizes.reduce(0, +)), countStyle: .file))
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                action("Quick Look", symbol: "eye") { cloud.quickLook(toggling: false) }
                action("Copy Links", symbol: "link") { cloud.copyLinks(uploads) }
                action("Delete from Cloud…", symbol: "icloud.slash") { cloud.pendingDelete = uploads }
                    .disabled(cloud.isBusy)
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
