import AppKit
import SwiftUI

struct CaptureLibraryView: View {
    @State private var model = CaptureLibraryModel.shared
    @State private var history = ScreenshotHistoryStore.shared
    @State private var projects = RecordingProjectStore.shared
    @State private var libraryWindow: NSWindow?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @AppStorage("captureLibrary.layout") private var layout: CaptureLibraryLayout = .grid
    @AppStorage("captureLibrary.inspectorVisible") private var inspectorVisible = true
    @AppStorage("captureLibrary.cardWidth") private var cardWidth = 220.0
    @AppStorage("captureLibrary.sort") private var savedSort: CaptureLibrarySort = .newest

    private var activeFilter: CaptureLibraryFilter { model.filter ?? .all }

    /// The sidebar picks either a kind of capture or a tag.
    private var sidebarSelection: Binding<CaptureLibrarySidebarSelection?> {
        Binding {
            if let tag = model.tagFilter { return .tag(tag) }
            return model.filter.map { .kind($0) }
        } set: { selection in
            switch selection {
            case .tag(let tag):
                model.filter = .all
                model.tagFilter = tag
            case .kind(let filter):
                model.tagFilter = nil
                model.filter = filter
            case nil:
                model.tagFilter = nil
                model.filter = nil
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                Section("Library") {
                    ForEach(CaptureLibraryFilter.allCases) { filter in
                        Label {
                            HStack {
                                Text(filter.title)
                                Spacer()
                                Text(model.count(for: filter), format: .number)
                                    .foregroundStyle(.secondary)
                                    .font(.caption.monospacedDigit())
                            }
                        } icon: { Image(systemName: filter.symbol) }
                        .tag(CaptureLibrarySidebarSelection.kind(filter))
                    }
                }
                if !model.tags.isEmpty {
                    Section("Tags") {
                        ForEach(model.tags, id: \.self) { tag in
                            Label {
                                HStack {
                                    Text(tag)
                                    Spacer()
                                    Text(model.tagCounts[tag] ?? 0, format: .number)
                                        .foregroundStyle(.secondary)
                                        .font(.caption.monospacedDigit())
                                }
                            } icon: { CaptureTagIcon(tag: tag) }
                            .tag(CaptureLibrarySidebarSelection.tag(tag))
                            .contextMenu { CaptureTagAppearanceMenu(tag: tag) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            .safeAreaInset(edge: .bottom) {
                Button {
                    SettingsWindowController.show(tab: .general)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .modifier(LibrarySidebarSurface())
        } detail: {
            VStack(spacing: 0) {
                // Empty pages are only as tall as their message; fill the column anyway.
                browser.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }
            .modifier(LibraryDetailCorners())
            // Inside the detail column the inspector sits under the toolbar,
            // so the toolbar runs unbroken across it.
            .inspector(isPresented: $inspectorVisible) {
                CaptureLibraryInspector(model: model)
                    // The inspector column paints its own grey, under the
                    // toolbar too, so its content carries the sidebar's.
                    .modifier(LibrarySidebarSurface())
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .modifier(LibraryWindowSurface())
            .navigationTitle(model.tagFilter ?? activeFilter.title)
            .navigationSubtitle("Screendrop")
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search captures")
        .toolbar { toolbar }
        .frame(minWidth: 860, minHeight: 540)
        .onAppear {
            AppActivationPolicy.enter()
            model.sortOrder = savedSort
            model.refresh()
        }
        .onDisappear { AppActivationPolicy.leave() }
        .onWindowChange { window in
            libraryWindow = window
            PreviewWindowCaptureExclusion.shared.register(window: window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === libraryWindow { model.refresh() }
        }
        .onChange(of: history.items) { _, _ in model.refresh() }
        .onChange(of: projects.projects) { _, _ in model.refresh() }
        .onChange(of: model.sortOrder) { _, value in savedSort = value }
        .alert("Move \(model.pendingTrash.count == 1 ? "capture" : "\(model.pendingTrash.count) captures") to Trash?", isPresented: Binding(
            get: { !model.pendingTrash.isEmpty },
            set: { if !$0 { model.pendingTrash = [] } }
        )) {
            Button("Move to Trash", role: .destructive) { model.movePendingItemsToTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = [] }
        } message: {
            Text("The local files and their edits will move to Trash. Exported copies and cloud links will remain available.")
        }
        .alert("The Library action could not be completed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder private var browser: some View {
        if !model.hasLoaded {
            ProgressView("Loading Library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleItems.isEmpty {
            if !model.searchText.isEmpty {
                ContentUnavailableView {
                    Label("No Results for “\(model.searchText)”", systemImage: "magnifyingglass")
                } description: {
                    Text(activeFilter == .all
                        ? "Check the spelling or try a new search."
                        : "Nothing in \(activeFilter.title) matches. Check the spelling, or search all your captures.")
                } actions: {
                    HStack {
                        if activeFilter != .all {
                            // Widening keeps the query and may find the other
                            // kind of capture, so it's the likeliest next step.
                            Button("Search All Captures") { model.filter = .all }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Clear Search") { model.searchText = "" }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                }
            } else {
                ContentUnavailableView {
                    Label(emptyLibraryTitle, systemImage: activeFilter.symbol)
                } description: {
                    Text(emptyLibraryDescription)
                } actions: {
                    VStack(spacing: 12) {
                        emptyActions
                        if let shortcutLine {
                            Text(shortcutLine)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } else {
            CaptureLibraryCollection(items: model.visibleItems, revision: model.contentRevision, layout: layout,
                cardWidth: cardWidth, selection: $model.selection, isBusy: model.isBusy, onAction: model.perform)
        }
    }

    private var emptyLibraryTitle: String {
        switch activeFilter {
        case .all: "No Captures Yet"
        case .screenshots: "No Screenshots Yet"
        case .recordings: "No Recordings Yet"
        }
    }

    private var emptyLibraryDescription: String {
        switch activeFilter {
        case .all: "Screenshots and recordings you make appear here."
        case .screenshots: "Capture an area, a window or the whole screen."
        case .recordings: "Record your screen, a window or an area."
        }
    }

    /// One prominent button for the page's likeliest action and at most one
    /// standard one beside it, at the same size (HIG: Buttons).
    private var emptyActions: some View {
        HStack {
            switch activeFilter {
            case .all:
                captureAreaButton.buttonStyle(.borderedProminent)
                recordScreenButton.buttonStyle(.bordered)
            case .screenshots:
                captureAreaButton.buttonStyle(.borderedProminent)
                Button("Capture Window") { CaptureCoordinator.shared.captureWindow() }
                    .buttonStyle(.bordered)
            case .recordings:
                recordScreenButton.buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    /// The page's capture shortcuts as the user set them, so an empty page
    /// teaches the keys that work from anywhere. Keys that failed to register
    /// are left out, and with none left there's no line at all. Non-breaking
    /// spaces keep each key with its name, so the line wraps between them.
    private var shortcutLine: String? {
        let actions: [(CaptureHotkeyAction, String)] = switch activeFilter {
        case .all: [(.area, "Area"), (.window, "Window"), (.fullscreen, "Screen"), (.screenRecording, "Record")]
        case .screenshots: [(.area, "Area"), (.window, "Window"), (.fullscreen, "Screen")]
        case .recordings: [(.screenRecording, "Record")]
        }
        let keys = actions
            .filter { HotkeyManager.shared.registrationErrors[$0.0] == nil }
            .map { CaptureHotkeyPreferences.shortcut(for: $0.0).displayTokens.joined() + "\u{00A0}" + $0.1 }
        guard !keys.isEmpty else { return nil }
        let heading = keys.count == 1 ? "Shortcut that works anywhere" : "Shortcuts that work anywhere"
        return heading + "\n" + keys.joined(separator: "\u{00A0}· ")
    }

    private var captureAreaButton: some View {
        Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
    }

    /// The ellipsis: it opens the recording picker rather than starting at once.
    private var recordScreenButton: some View {
        Button("Record Screen…") { RecordingPickerPresenter.shared.show() }
            .disabled(ScreenRecordingManager.shared.isActive)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let title = model.operationTitle {
                ProgressView().controlSize(.mini)
                Text(title)
            } else {
                Text("\(model.visibleItems.count) \(model.visibleItems.count == 1 ? "capture" : "captures")")
                if !model.selection.isEmpty { Text("· \(model.selection.count) selected") }
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.mini).help("Refreshing Library") }
            if layout == .grid {
                // Capped where the 640 px thumbnails stay sharp on Retina.
                Slider(value: $cardWidth, in: 140...320) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "photo").imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "photo").imageScale(.large)
                }
                .controlSize(.mini)
                .frame(width: 150)
                .accessibilityLabel("Card size")
                .help("Card size")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        // Keep the status bar out of the column's minimum width. With the card
        // size slider counted in it, resizing the window looped in AppKit's
        // constraint pass until it crashed.
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 30)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Capture Fullscreen", systemImage: "macwindow") { CaptureCoordinator.shared.captureFullscreen() }
                Button("Capture Window", systemImage: "macwindow.on.rectangle") { CaptureCoordinator.shared.captureWindow() }
                Button("Capture Area", systemImage: "rectangle.dashed") { CaptureCoordinator.shared.captureArea() }
                Divider()
                Button("Record Screen", systemImage: "record.circle") { RecordingPickerPresenter.shared.show() }
                    .disabled(ScreenRecordingManager.shared.isActive)
            } label: { Label("New Capture", systemImage: "plus") }
            .help("New capture")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $layout) {
                Label("Grid View", systemImage: "square.grid.2x2").tag(CaptureLibraryLayout.grid).help("Grid view")
                Label("List View", systemImage: "list.bullet").tag(CaptureLibraryLayout.list).help("List view")
            }
            .labelStyle(.iconOnly)
            .pickerStyle(.segmented)
            .help("Switch between grid and list")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $model.sortOrder) {
                    ForEach(CaptureLibrarySort.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .help("Sort captures")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.perform(.preview) } label: { Label("Quick Look", systemImage: "eye") }
                .disabled(model.selection.count != 1 || model.isBusy)
                .help("Quick Look (Space)")
            Button { model.perform(.edit) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                .disabled(model.selection.count != 1 || model.isBusy)
                .help("Open in the screenshot or recording editor")
            Menu {
                Button("Copy", systemImage: "doc.on.doc") { model.perform(.copy) }
                Button("Export…", systemImage: "square.and.arrow.up") { model.perform(.export) }
                Button("Rename", systemImage: "pencil") { model.perform(.rename) }
                    .disabled(model.selection.count != 1)
                Button("Reveal in Finder", systemImage: "folder") { model.perform(.reveal) }
                Divider()
                Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.perform(.trash) }
            } label: { Label("Actions", systemImage: "ellipsis.circle") }
            .disabled(model.selection.isEmpty || model.isBusy)
            .help("Capture actions")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { inspectorVisible.toggle() } label: {
                Label(inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
        }
    }
}

/// Share one adaptive color between the sidebar and the detail's corner
/// cutouts; separate visual-effect views can resolve to different tints.
private struct LibrarySidebarSurface: ViewModifier {
    static var background: Color { Color(nsColor: NSColor(name: nil, dynamicProvider: chrome)) }

    /// A darker grey than the system's in light mode, so the white card stands
    /// out. Dark mode keeps the system colour. Nonisolated: AppKit can resolve
    /// colours off the main thread.
    nonisolated private static func chrome(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .underPageBackgroundColor
            : NSColor(srgbRed: 230 / 255, green: 230 / 255, blue: 230 / 255, alpha: 1)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background {
                    Self.background.ignoresSafeArea(.container)
                }
        } else {
            content
        }
    }
}

/// The detail as a raised card below the toolbar, rounded all round, with a
/// margin to the sidebar, the inspector and the window's bottom edge so its
/// shadow shows on every side. It goes before `.inspector`: a clip around the
/// inspector drops the column's safe area, and the grid then lays out under
/// the sidebar and the toolbar.
private struct LibraryDetailCorners: ViewModifier {
    @Environment(\.displayScale) private var displayScale

    private let card = RoundedRectangle(cornerRadius: 16, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            content
                .clipShape(card)
                // The fill sits outside the clip, so its shadow isn't cut off.
                .background {
                    card
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                }
                .overlay {
                    card
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1 / displayScale)
                        .allowsHitTesting(false)
                }
                .padding([.horizontal, .bottom], 12)
        } else {
            content
        }
    }
}

/// The sidebar's grey behind the detail column and the toolbar, so the
/// toolbar reads as one strip. Backgrounds around `.inspector` keep the safe
/// area; clips don't.
private struct LibraryWindowSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            content
                .background { LibrarySidebarSurface.background.ignoresSafeArea() }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

enum CaptureLibrarySidebarSelection: Hashable {
    case kind(CaptureLibraryFilter)
    case tag(String)
}
