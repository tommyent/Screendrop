import AppKit
import SwiftUI

struct CaptureLibraryInspector: View {
    let model: CaptureLibraryModel
    @State private var byteCount: Int64?
    @State private var pendingCloudDelete: CaptureLibraryItem?
    @State private var pendingCloudUpload: CaptureLibraryItem?
    @State private var tooltip = BarTooltipModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var items: [CaptureLibraryItem] { model.selectedItems }

    var body: some View {
        Group {
            if items.isEmpty {
                LibraryInspectorPlaceholder(
                    symbol: "photo.on.rectangle.angled", title: "Capture details",
                    message: "Select a screenshot or recording\nto take a closer look."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: InspectorMetrics.sectionVerticalPadding) {
                        if items.count == 1, let item = items.first {
                            header(item)
                            Divider()
                            information(item)
                        } else {
                            multipleSelection
                        }
                        Divider()
                        tagsSection
                    }
                    .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.vertical, InspectorMetrics.sectionVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !items.isEmpty { actionBar.modifier(LibraryInspectorBarSurface()) }
        }
        .environment(tooltip)
        .onChange(of: items.map(\.id)) { _, _ in
            tooltip.dismiss()
            pendingCloudUpload = nil
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if isBusy { tooltip.dismiss() }
        }
        .onDisappear { tooltip.dismiss() }
        .task(id: items.map(\.thumbnailKey)) {
            byteCount = nil
            let urls = items.map(\.ownedURL)
            let scan = Task.detached(priority: .utility) {
                urls.reduce(Int64(0)) { total, url in
                    Task.isCancelled ? total : total + CaptureLibraryScanner.sizeOnDisk(of: url)
                }
            }
            let size = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            byteCount = size
        }
        .alert("Delete from cloud?", isPresented: Binding(
            get: { pendingCloudDelete != nil }, set: { if !$0 { pendingCloudDelete = nil } }
        ), presenting: pendingCloudDelete) { item in
            Button("Delete", role: .destructive) {
                model.deleteCloudCopy(item)
                pendingCloudDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingCloudDelete = nil }
        } message: { _ in
            Text("This permanently removes the cloud copy and breaks its share link. Your local capture stays in the Library.")
        }
    }

    private func header(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { model.perform(.preview) } label: {
                CaptureLibraryThumbnail(item: item)
                    .aspectRatio(1.45, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: item.isVideo ? "play.fill" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(10)
                    }
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityLabel("Quick Look \(item.name)")
            .help("Open a large preview")

            VStack(alignment: .leading, spacing: 7) {
                LibraryInspectorTitle(item: item, model: model)
                    .id(item.id)
                HStack(spacing: 8) {
                    Text(item.kindTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.hasDraft {
                        statusBadge("Draft", symbol: "circle.lefthalf.filled")
                    } else if item.hasEdits {
                        statusBadge("Edited", symbol: "slider.horizontal.3")
                    }
                }
            }
        }
    }

    /// A fixed Finder-style action strip. All controls use the same icon size,
    /// hit area and hover surface, including the native menu trigger.
    private var actionBar: some View {
        HStack(spacing: 0) {
            actionButton(
                .edit, id: .libraryEdit,
                title: items.first?.isVideo == true ? "Edit Recording" : "Annotate Screenshot",
                symbol: items.first?.isVideo == true ? "film" : "pencil.tip.crop.circle"
            )
            .disabled(items.count != 1)
            actionButton(.copy, id: .libraryCopy, title: "Copy", symbol: "doc.on.doc")
            actionButton(.export, id: .libraryExport, title: "Export", symbol: "square.and.arrow.up")
            if CloudUploader.shared.isConfigured || items.contains(where: { $0.cloudURL != nil }) {
                cloudAction
            }
            moreActions(allowsRename: items.count == 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .disabled(model.isBusy)
        .coordinateSpace(name: LibraryInspectorActionChrome.coordinateSpace)
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let target = tooltip.visible {
                    let width = geometry.size.width
                    let verticalOffset = -(BarTooltip.gap + BarTooltip.pillHeight)
                    BarTooltipPill(text: target.text)
                        .visualEffect { content, pill in
                            // Keep the end controls' tooltips inside the narrow inspector.
                            content.offset(
                                x: max(8, min(target.frame.midX - pill.size.width / 2,
                                              width - pill.size.width - 8)),
                                y: verticalOffset
                            )
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: tooltip.visible?.id)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: tooltip.visible?.text)
        }
    }

    private func actionButton(_ action: CaptureLibraryAction, id: BarTooltipID, title: String, symbol: String) -> some View {
        Button {
            tooltip.dismiss()
            model.perform(action)
        } label: {
            actionIcon(symbol)
                .modifier(LibraryInspectorActionChrome(id: id, title: title))
        }
        .buttonStyle(BarButtonStyle())
        .accessibilityLabel(title)
    }

    private var cloudAction: some View {
        let item = items.count == 1 ? items.first : nil
        let isShared = item?.cloudURL != nil
        let title = isShared ? "Copy Cloud Link" : "Share to Cloud"
        return Button {
            tooltip.dismiss()
            guard let item else { return }
            if isShared {
                model.copyLink(item)
            } else {
                pendingCloudUpload = item
            }
        } label: {
            actionIcon(isShared ? "link" : "arrow.up.circle")
                .modifier(LibraryInspectorActionChrome(id: .libraryCloud, title: title))
        }
        .buttonStyle(BarButtonStyle())
        .accessibilityLabel(title)
        .disabled(item == nil)
        .popover(item: $pendingCloudUpload, arrowEdge: .top) { item in
            CloudUploadOptionsPopover(suggestedTitle: item.name) { options in
                model.upload(item, options: options)
            }
        }
    }

    private func actionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
    }

    private func information(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.headerSpacing) {
            sectionTitle("Information")
            VStack(spacing: InspectorMetrics.rowSpacing) {
                detailRow("Dimensions", value: item.dimensions)
                if item.isVideo { detailRow("Duration", value: item.durationText) }
                detailRow("Size on disk", value: sizeText)
                detailRow("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailRow("Modified", value: item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var multipleSelection: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.sectionVerticalPadding) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(Array(items.prefix(3))) { item in
                        CaptureLibraryThumbnail(item: item)
                            .frame(maxWidth: .infinity)
                            .frame(height: 68)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            }
                    }
                }
                Text("\(items.count) captures selected")
                    .font(.system(size: 16, weight: .semibold))
            }
            Divider()
            VStack(alignment: .leading, spacing: InspectorMetrics.headerSpacing) {
                sectionTitle("Selection")
                VStack(spacing: InspectorMetrics.rowSpacing) {
                    detailRow("Screenshots", value: "\(items.filter { !$0.isVideo }.count)")
                    detailRow("Recordings", value: "\(items.filter(\.isVideo).count)")
                    detailRow("Size on disk", value: sizeText)
                }
            }
        }
    }

    private func moreActions(allowsRename: Bool) -> some View {
        Menu {
            if allowsRename {
                Button("Rename", systemImage: "pencil") {
                    if let item = items.first { model.beginRename(item, at: .inspector) }
                }
            }
            Button("Reveal in Finder", systemImage: "folder") { model.perform(.reveal) }
            if items.count == 1, let item = items.first, let link = item.cloudURL {
                Divider()
                Button("Copy Cloud Link", systemImage: "link") { model.copyLink(item) }
                if let url = URL(string: link) {
                    Link(destination: url) { Label("Open Shared Capture", systemImage: "arrow.up.right") }
                }
                Button("Delete from Cloud…", systemImage: "trash", role: .destructive) {
                    pendingCloudDelete = item
                }
            }
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.perform(.trash) }
        } label: {
            actionIcon("ellipsis")
                .modifier(LibraryInspectorActionChrome(id: .libraryMore, title: "More Actions"))
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .simultaneousGesture(TapGesture().onEnded { tooltip.dismiss() })
        .accessibilityLabel("More capture actions")
    }

    /// The tags every selected capture shares. Adding or removing one
    /// applies to all of them, so a selection can be tagged in one go.
    private var tagsSection: some View {
        let shared = items.dropFirst().reduce(Set(items.first?.tags ?? [])) { $0.intersection($1.tags) }
        let tags = (items.first?.tags ?? []).filter(shared.contains)
        let suggestions = model.tags.filter { !shared.contains($0) }
        return VStack(alignment: .leading, spacing: InspectorMetrics.headerSpacing) {
            sectionTitle("Tags")
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 6) {
                    Label { Text(tag) } icon: { CaptureTagIcon(tag: tag) }
                    Spacer(minLength: 4)
                    Menu {
                        CaptureTagAppearanceMenu(tag: tag)
                    } label: {
                        Image(systemName: "paintpalette")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.tertiary)
                    .help("Color and icon for this tag, everywhere in the Library")
                    .accessibilityLabel("Color and icon for tag \(tag)")
                    Button {
                        model.setTag(tag, applied: false)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(items.count == 1 ? "Remove tag" : "Remove tag from all selected")
                    .accessibilityLabel("Remove tag \(tag)")
                }
                .font(.system(size: 12))
            }
            CaptureTagField(available: suggestions,
                            placeholder: items.count == 1 ? "Add tag" : "Tag \(items.count) captures") { name in
                model.setTag(name, applied: true)
            }
            // A new selection starts with an empty field.
            .id(items.map(\.id))
            .disabled(model.isBusy)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.inspectorSectionHeader)
            .foregroundStyle(InspectorControlPalette.label)
    }

    /// Label primary, value secondary, as Preview's Info inspector reads.
    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(InspectorControlPalette.label).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func statusBadge(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.055), in: Capsule())
    }

    private var sizeText: String {
        byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…"
    }
}

private struct LibraryInspectorActionChrome: ViewModifier {
    static let coordinateSpace = "libraryInspectorActions"
    let id: BarTooltipID
    let title: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(BarTooltipModel.self) private var tooltip
    @State private var isHovering = false
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            // Size the actual control label, so its whole slot shares the
            // same click, hover and tooltip area, including the empty space.
            .frame(minWidth: 40, maxWidth: .infinity)
            .frame(height: 36)
            .background(
                Color.primary.opacity(isHovering && isEnabled ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(Self.coordinateSpace))
            } action: { frame in
                self.frame = frame
            }
            .onHover { hovering in
                isHovering = hovering
                updateTooltip()
            }
            .onChange(of: title) { _, _ in updateTooltip() }
            .onChange(of: isEnabled) { _, _ in updateTooltip() }
            .onDisappear { tooltip.endHover(id: id) }
    }

    private func updateTooltip() {
        if isHovering && isEnabled {
            tooltip.hover(id: id, text: title, frame: frame)
        } else {
            tooltip.endHover(id: id)
        }
    }
}

/// The capture's name, renamed in place like a name in Finder: click it to
/// edit, Return or clicking away renames, Esc leaves it as it was.
private struct LibraryInspectorTitle: View {
    let item: CaptureLibraryItem
    let model: CaptureLibraryModel

    var body: some View {
        if model.renameSession?.id == item.id, model.renameSession?.location == .inspector {
            CaptureNameField(id: item.id, location: .inspector, font: .system(size: 16, weight: .semibold))
        } else {
            // A plain button rather than a tap gesture, so assistive
            // technologies can press it too.
            Button {
                model.beginRename(item, at: .inspector)
            } label: {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .help("Click to rename")
            .accessibilityHint("Rename")
        }
    }
}

/// What a Library inspector shows with nothing selected: the same quiet
/// block for captures, uploads and comments. Its title stays secondary, so
/// it never outshines the cards beside it (design pass).
struct LibraryInspectorPlaceholder: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Space.xxl)
    }
}

/// A Library inspector's bottom action bar on its own opaque strip, in the
/// inspector column's colour, with the hairline the editor's preset bar has.
/// The content still scrolls fully above it (it's a safe-area inset); while
/// it scrolls past, the bar covers it instead of its text showing through
/// the icons (sd-305).
struct LibraryInspectorBarSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .background {
                Group {
                    if #available(macOS 27.0, *) {
                        WorkspaceChrome.background
                    } else {
                        Color(nsColor: .windowBackgroundColor)
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 0.5)
            }
    }
}
