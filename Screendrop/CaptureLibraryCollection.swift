import AppKit
import SwiftUI

enum CaptureLibraryAction: String {
    case preview = "Quick Look"
    case edit = "Edit"
    case rename = "Rename"
    case copy = "Copy"
    case export = "Export…"
    case reveal = "Reveal in Finder"
    case trash = "Move to Trash"

    /// The captures' context menu, for `count` selected.
    static func menu(selected count: Int, perform: @escaping (Self) -> Void) -> [LibraryMenuItem] {
        [Self.preview, .edit, .rename, .copy, .export, .reveal, .trash].map { action in
            LibraryMenuItem(
                title: action.rawValue,
                isEnabled: !(action == .rename || action == .edit || action == .preview) || count == 1,
                startsGroup: action == .copy || action == .trash
            ) { perform(action) }
        }
    }
}

/// A context menu entry for the Library's collection.
struct LibraryMenuItem {
    let title: String
    var isEnabled = true
    /// Drawn after a separator.
    var startsGroup = false
    let perform: () -> Void
}

/// Both layouts use NSCollectionView's reuse queue. Changing selection doesn't
/// reload the collection; data changes reconcile selection by stable media IDs.
/// Captures and cloud uploads share it, so both select, open and delete alike;
/// the keys and clicks arrive as `CaptureLibraryAction`s.
struct CaptureLibraryCollection<Entry: Identifiable>: NSViewRepresentable where Entry.ID == String {
    let items: [Entry]
    let revision: Int
    let layout: CaptureLibraryLayout
    let cardWidth: CGFloat
    @Binding var selection: Set<String>
    let isBusy: Bool
    var accessibilityLabel = "Captures"
    /// The card for an entry, given whether it's selected and a callback for
    /// where its title is drawn (clicking the title renames).
    let cell: (Entry, Bool, @escaping (CGRect) -> Void) -> AnyView
    /// The context menu, for the number of selected entries.
    let menu: (Int) -> [LibraryMenuItem]
    let onAction: (CaptureLibraryAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let collection = LibraryCollectionView()
        collection.autoresizingMask = [.width]
        collection.setAccessibilityLabel(accessibilityLabel)
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.configureLayout(layout)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.command = { [weak coordinator = context.coordinator] action in
            guard let coordinator, !coordinator.parent.isBusy else { return }
            if action == .edit { coordinator.selectionChanged() }
            coordinator.parent.onAction(action)
        }
        collection.contextMenuProvider = { [weak coordinator = context.coordinator] event in
            coordinator?.menu(for: event)
        }
        collection.mouseSelectionHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.handleMouseSelection(event)
        }
        scrollView.documentView = collection
        context.coordinator.collection = collection
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let old = coordinator.parent
        coordinator.parent = self
        guard let collection = coordinator.collection else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        if old.revision != revision || old.layout != layout || coordinator.initialLoad {
            coordinator.initialLoad = false
            coordinator.indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
            (collection.collectionViewLayout as? LibraryCollectionLayout)?.displayLayout = layout
            collection.reloadData()
            collection.collectionViewLayout?.invalidateLayout()
        }
        if let flow = collection.collectionViewLayout as? LibraryCollectionLayout, flow.cardWidth != cardWidth {
            flow.cardWidth = cardWidth
            flow.invalidateLayout()
        }
        let paths = Set(selection.compactMap { id in
            coordinator.indices[id].map { IndexPath(item: $0, section: 0) }
        })
        if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: CaptureLibraryCollection
        weak var collection: LibraryCollectionView?
        var updating = false
        var initialLoad = true
        var indices: [String: Int] = [:]
        private var selectionAnchorID: String?
        private var pendingRange: (anchor: String, end: String)?
        private var menuItems: [LibraryMenuItem] = []

        init(_ parent: CaptureLibraryCollection) { self.parent = parent }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: LibraryCollectionItem.identifier, for: indexPath)
            configure(cell, at: indexPath)
            return cell
        }

        private func configure(_ item: NSCollectionViewItem, at indexPath: IndexPath) {
            guard let cell = item as? LibraryCollectionItem, parent.items.indices.contains(indexPath.item) else { return }
            let entry = parent.items[indexPath.item]
            let draw = parent.cell
            cell.configure { selected, onTitleFrame in draw(entry, selected, onTitleFrame) }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? LibraryCollectionItem)?.clearContent()
        }

        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            configure(item, at: indexPath)
        }

        fileprivate func selectionChanged() {
            guard !updating, let collection else { return }
            parent.selection = Set(collection.selectionIndexPaths.compactMap {
                parent.items.indices.contains($0.item) ? parent.items[$0.item].id : nil
            })
            if parent.selection.count == 1 { selectionAnchorID = parent.selection.first }
        }

        func handleMouseSelection(_ event: NSEvent) {
            guard let collection else { return }
            let path = collection.indexPathForItem(at: collection.convert(event.locationInWindow, from: nil))
            if event.type == .leftMouseDown {
                pendingRange = nil
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.shift), flags.isDisjoint(with: [.command, .control, .option]),
                      let path, parent.items.indices.contains(path.item) else { return }
                let anchor = selectionAnchorID.flatMap { indices[$0] }
                    .map { IndexPath(item: $0, section: 0) }
                    .flatMap { collection.selectionIndexPaths.contains($0) ? $0 : nil }
                    ?? collection.selectionIndexPaths.min()
                if let anchor, parent.items.indices.contains(anchor.item) {
                    pendingRange = (parent.items[anchor.item].id, parent.items[path.item].id)
                }
            } else if event.type == .leftMouseUp {
                let range = pendingRange
                pendingRange = nil
                guard let path, parent.items.indices.contains(path.item) else {
                    selectionAnchorID = nil
                    return
                }
                let clickedID = parent.items[path.item].id
                guard let range else {
                    selectionAnchorID = collection.selectionIndexPaths.contains(path) ? clickedID : nil
                    return
                }
                // Keep native click/keyboard focus, but select a linear range in
                // display order. Resolve IDs again in case a refresh reordered items.
                guard clickedID == range.end, let start = indices[range.anchor], let end = indices[range.end] else { return }
                collection.selectionIndexPaths = Set((min(start, end)...max(start, end)).map {
                    IndexPath(item: $0, section: 0)
                })
                selectionAnchorID = range.anchor
                selectionChanged()
            }
        }

        func menu(for event: NSEvent) -> NSMenu? {
            guard let collection,
                  let path = collection.indexPathForItem(at: collection.convert(event.locationInWindow, from: nil)) else { return nil }
            if !collection.selectionIndexPaths.contains(path) {
                collection.selectionIndexPaths = [path]
                selectionChanged()
            }
            menuItems = parent.menu(collection.selectionIndexPaths.count)
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (index, entry) in menuItems.enumerated() {
                if entry.startsGroup { menu.addItem(.separator()) }
                let item = NSMenuItem(title: entry.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.isEnabled = !parent.isBusy && entry.isEnabled
                menu.addItem(item)
            }
            return menu
        }

        @objc private func performMenuItem(_ sender: NSMenuItem) {
            guard menuItems.indices.contains(sender.tag), !parent.isBusy else { return }
            menuItems[sender.tag].perform()
        }
    }
}

final class LibraryCollectionView: NSCollectionView {
    var command: ((CaptureLibraryAction) -> Void)?
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?
    var mouseSelectionHandler: ((NSEvent) -> Void)?

    func configureLayout(_ displayLayout: CaptureLibraryLayout) {
        let flow = LibraryCollectionLayout()
        flow.displayLayout = displayLayout
        // Installing a layout initializes AppKit's data-source/reuse machinery.
        // Registering first loses the class registration and makes the first
        // dequeue fall back to a nonexistent CaptureLibraryCell nib.
        collectionViewLayout = flow
        register(LibraryCollectionItem.self, forItemWithIdentifier: LibraryCollectionItem.identifier)
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?(event) }

    private var pendingRename: DispatchWorkItem?

    /// Clicking the title of the one selected capture renames it, as in
    /// Finder. It waits out the double-click interval first, so a double
    /// click still opens the editor, and a click that selects a capture never does.
    override func mouseDown(with event: NSEvent) {
        pendingRename?.cancel()
        pendingRename = nil
        let clicked = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        let wasOnlySelection = clicked.map { selectionIndexPaths == [$0] } ?? false
        mouseSelectionHandler?(event)
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            guard let clicked else { return }
            selectionIndexPaths = [clicked]
            command?(.edit)
            return
        }
        guard event.clickCount == 1, wasOnlySelection, let clicked,
              let cell = item(at: clicked) as? LibraryCollectionItem,
              cell.titleContains(event.locationInWindow) else { return }
        // Only if that capture is still the one selected when it fires, and
        // the keyboard is still here: clicking into Search in the meantime
        // must not have its typing turned into a rename.
        let rename = DispatchWorkItem { [weak self] in
            guard let self, selectionIndexPaths == [clicked],
                  let window, window.isKeyWindow,
                  (window.firstResponder as? NSView)?.isDescendant(of: self) == true else { return }
            command?(.rename)
        }
        pendingRename = rename
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: rename)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        mouseSelectionHandler?(event)
    }

    override func keyDown(with event: NSEvent) {
        pendingRename?.cancel()
        pendingRename = nil
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers == "c" { command?(.copy); return }
        if flags.contains(.command), event.keyCode == 51 { command?(.trash); return }
        if !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            if event.keyCode == 49 { command?(.preview); return }
            if event.keyCode == 36 { command?(.rename); return }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { command?(.copy) }
}

final class LibraryCollectionLayout: NSCollectionViewFlowLayout {
    var displayLayout: CaptureLibraryLayout = .grid
    /// Grid cell width, from the Library's card size slider.
    var cardWidth: CGFloat = 220
    /// The width the cells were last sized for.
    private var preparedWidth: CGFloat?

    private var availableWidth: CGFloat {
        max(200, collectionView?.enclosingScrollView?.contentSize.width ?? 800)
    }

    override func prepare() {
        let width = availableWidth
        preparedWidth = width
        sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        minimumInteritemSpacing = 16
        minimumLineSpacing = displayLayout == .grid ? 16 : 6
        if displayLayout == .grid {
            // Finder-style: cells keep one size and a wider window fits more
            // columns. The gaps share the leftover width up to 32 pt; past
            // that it goes to the side margins, so the block sits centred
            // instead of spreading 80 pt gaps between 18 pt rows (design pass
            // choice 3). A part-filled last row keeps to the same columns.
            let cellWidth = min(cardWidth, width - 32)
            itemSize = CGSize(width: cellWidth, height: floor(cellWidth * 0.625) + 62)
            let columns = max(1, floor((width - 16) / (cellWidth + 16)))
            let space = min(32, max(16, floor((width - columns * cellWidth) / (columns + 1))))
            let rowWidth = columns * cellWidth + (columns - 1) * space
            minimumInteritemSpacing = space
            sectionInset.left = max(16, floor((width - rowWidth) / 2))
            // Rounding goes to the right margin, less half a point of slack so
            // the last column can't wrap to the next row.
            sectionInset.right = max(16, width - rowWidth - sectionInset.left - 0.5)
        } else {
            itemSize = CGSize(width: width - 32, height: 76)
        }
        super.prepare()
    }

    /// Compared with the width the cells were sized for, not the collection
    /// view's own bounds: by the time a window resize asks, those already
    /// have the new size.
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        availableWidth != preparedWidth
    }

    /// The flow layout keeps the item sizes it measured, so a new `itemSize`
    /// from `prepare()` only took effect on the next data reload, such as
    /// switching to list and back.
    override func invalidationContext(forBoundsChange newBounds: NSRect) -> NSCollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        (context as? NSCollectionViewFlowLayoutInvalidationContext)?.invalidateFlowLayoutDelegateMetrics = true
        return context
    }
}

final class LibraryCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CaptureLibraryCell")
    /// Draws the entry for a selection state; nil while the cell is unused.
    private var content: ((Bool, @escaping (CGRect) -> Void) -> AnyView)?
    private var host: NSHostingView<AnyView>?
    /// Where the title is drawn, in the cell's own (flipped) coordinates.
    private var titleFrame: CGRect = .zero

    func titleContains(_ windowPoint: NSPoint) -> Bool {
        titleFrame.contains(view.convert(windowPoint, from: nil))
    }

    override func loadView() {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        self.host = host
        view = host
    }

    override var isSelected: Bool { didSet { updateContent() } }

    func configure(_ content: @escaping (Bool, @escaping (CGRect) -> Void) -> AnyView) {
        self.content = content
        updateContent()
    }

    func clearContent() {
        content = nil
        titleFrame = .zero
        updateContent()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearContent()
    }

    private func updateContent() {
        _ = view
        host?.rootView = content?(isSelected) { [weak self] frame in self?.titleFrame = frame } ?? AnyView(EmptyView())
    }
}

struct LibraryCellContent: View {
    let item: CaptureLibraryItem?
    let layout: CaptureLibraryLayout
    let selected: Bool
    var onTitleFrame: (CGRect) -> Void = { _ in }
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Group {
            if let item {
                Group {
                    if layout == .grid {
                        VStack(alignment: .leading, spacing: 8) {
                            thumbnail(item)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            labels(item)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                    } else {
                        HStack(spacing: 14) {
                            thumbnail(item).frame(width: 88, height: 58)
                            labels(item)
                            Spacer(minLength: 8)
                            Text(item.kindTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 8)
                        }
                    }
                }
                .padding(6)
                .background(
                    Color.primary.opacity(selected ? 0.075 : isHovering ? 0.035 : 0.012),
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                )
                // A solid backing in the chrome colour, so titles never sit on the grid's dots.
                .background(WorkspaceChrome.background, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(selected ? (contrast == .increased ? 0.65 : 0.28) : 0.08),
                            lineWidth: selected ? 1 : 0.5
                        )
                }
                .onHover { isHovering = $0 }
                .onChange(of: item.id) { _, _ in isHovering = false }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
                .accessibilityElement(children: isRenaming(item) ? .contain : .ignore)
                .accessibilityLabel("\(item.name), \(item.kindTitle), \(item.subtitle)"
                    + (item.tags.isEmpty ? "" : ", tags: \(item.tags.joined(separator: ", "))"))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityAction(named: "Rename") { CaptureLibraryModel.shared.beginRename(item, at: .card) }
            } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(Self.cellSpace))
    }

    private static let cellSpace = "LibraryCell"

    private func isRenaming(_ item: CaptureLibraryItem) -> Bool {
        let session = CaptureLibraryModel.shared.renameSession
        return session?.id == item.id && session?.location == .card
    }

    private func labels(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if isRenaming(item) {
                    CaptureNameField(id: item.id, location: .card, font: .system(size: 13, weight: .medium))
                } else {
                    Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.cellSpace)) } action: { onTitleFrame($0) }
                }
                if item.cloudURL != nil { Image(systemName: "link").foregroundStyle(.secondary) }
                if item.hasDraft { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange) }
            }
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func thumbnail(_ item: CaptureLibraryItem) -> some View {
        CaptureLibraryThumbnail(item: item)
            // Concentric inside the card: its radius minus its 6 pt padding.
            .clipShape(.rect(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .overlay(alignment: .topLeading) {
                if let tag = item.tags.first(where: { CaptureTagStyles.shared.color(for: $0) != nil }) ?? item.tags.first {
                    // One small badge rather than a mark per tag, so small
                    // cards keep room for their titles. The names are in the
                    // tooltip, the inspector and the accessibility label.
                    HStack(spacing: 3) {
                        CaptureTagIcon(tag: tag)
                        if item.tags.count > 1 {
                            Text("\(item.tags.count)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .padding(6)
                    .help(item.tags.joined(separator: ", "))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Label(item.durationText, systemImage: "play.fill")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(7)
                }
            }
    }
}
