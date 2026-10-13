import AppKit
import SwiftUI

struct CaptureLibraryInspector: View {
    let model: CaptureLibraryModel
    @State private var byteCount: Int64?
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
        .task(id: items.map(\.thumbnailKey)) {
            byteCount = nil
            let urls = items.flatMap(\.ownedFileURLs)
            let scan = Task.detached(priority: .utility) {
                urls.reduce(Int64(0)) { total, url in
                    Task.isCancelled ? total : total + CaptureLibraryScanner.sizeOnDisk(of: url)
                }
            }
            let size = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            byteCount = size
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
            .accessibilityLabel("Quick Look \(item.title)")
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

    private func information(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.headerSpacing) {
            sectionTitle("Information")
            VStack(spacing: InspectorMetrics.rowSpacing) {
                // The name on disk, which exports and drags keep; the title above may be a date.
                detailRow("File", value: item.ownedURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.ownedURL.lastPathComponent)
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

/// The capture's name, renamed in place like a name in Finder: click it to
/// edit, Return or clicking away renames, Esc leaves it as it was.
private struct LibraryInspectorTitle: View {
    let item: CaptureLibraryItem
    let model: CaptureLibraryModel

    var body: some View {
        if model.renameSession?.id == item.id, model.renameSession?.location == .inspector {
            CaptureNameField(id: item.id, location: .inspector, font: .system(size: 16, weight: .semibold), placeholder: item.dateTitle)
        } else {
            // A plain button rather than a tap gesture, so assistive
            // technologies can press it too.
            Button {
                model.beginRename(item, at: .inspector)
            } label: {
                Text(item.title)
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
