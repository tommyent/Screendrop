import AppKit
import SwiftUI

struct CaptureLibraryView: View {
    @State private var model = CaptureLibraryModel.shared
    @State private var cloud = CloudLibraryModel.shared
    @State private var comments = CommentsLibraryModel.shared
    @State private var history = ScreenshotHistoryStore.shared
    @State private var projects = RecordingProjectStore.shared
    @State private var libraryWindow: NSWindow?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @AppStorage("captureLibrary.layout") private var layout: CaptureLibraryLayout = .grid
    @AppStorage("captureLibrary.inspectorVisible") private var inspectorVisible = true
    @AppStorage("captureLibrary.tagsExpanded") private var tagsExpanded = true
    @AppStorage("captureLibrary.cardWidth") private var cardWidth = 220.0
    @AppStorage("captureLibrary.sort") private var savedSort: CaptureLibrarySort = .newest

    private var activeFilter: CaptureLibraryFilter { model.filter ?? .all }

    /// The sidebar picks a kind of capture, the cloud uploads or a tag.
    private var sidebarSelection: Binding<CaptureLibrarySidebarSelection?> {
        Binding {
            if comments.isShown { return .comments }
            if cloud.isShown { return .cloud }
            if let tag = model.tagFilter { return .tag(tag) }
            return model.filter.map { .kind($0) }
        } set: { selection in
            cloud.isShown = selection == .cloud
            comments.setShown(selection == .comments)
            switch selection {
            case .cloud, .comments:
                // The toolbar's capture actions mustn't act on captures out of sight.
                model.selection = []
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
                    Label {
                        HStack {
                            Text("Cloud")
                            Spacer()
                            if cloud.hasLoaded, CloudUploader.shared.isConfigured {
                                Text(cloud.uploads.count, format: .number)
                                    .foregroundStyle(.secondary)
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    } icon: { Image(systemName: "icloud") }
                    .tag(CaptureLibrarySidebarSelection.cloud)
                    Label {
                        HStack {
                            Text("Comments")
                            Spacer()
                            // New since the page was last opened, as Mail counts unread mail.
                            if comments.unreadCount > 0 {
                                Text(comments.unreadCount > 99 ? "99+" : comments.unreadCount.formatted())
                                    .foregroundStyle(.secondary)
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .accessibilityLabel("\(comments.unreadCount) new")
                            }
                        }
                    } icon: { Image(systemName: "bubble.left.and.bubble.right") }
                    .tag(CaptureLibrarySidebarSelection.comments)
                }
                if !model.tags.isEmpty {
                    Section("Tags", isExpanded: $tagsExpanded) {
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
                    .modifier(LibraryBrowserSurface(
                        showsDots: comments.isShown ? comments.visibleComments.isEmpty : layout == .grid || (cloud.isShown
                            ? cloud.visibleUploads.isEmpty
                            : !model.hasLoaded || model.visibleItems.isEmpty)
                    ))
                Divider()
                statusBar
            }
            .modifier(LibraryColumnSeparators(
                leading: columnVisibility != .detailOnly,
                trailing: inspectorVisible
            ))
            // Inside the detail column the inspector sits under the toolbar,
            // so the toolbar runs unbroken across it.
            .inspector(isPresented: $inspectorVisible) {
                Group {
                    if comments.isShown {
                        CommentInspector(comments: comments)
                    } else if cloud.isShown {
                        CloudUploadInspector(cloud: cloud)
                    } else {
                        CaptureLibraryInspector(model: model)
                    }
                }
                // The inspector column paints its own grey, under the
                // toolbar too, so its content carries the sidebar's.
                .modifier(LibrarySidebarSurface())
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .modifier(LibraryWindowSurface())
            .navigationTitle(comments.isShown ? "Comments" : cloud.isShown ? "Cloud" : model.tagFilter ?? activeFilter.title)
            .navigationSubtitle("Screendrop")
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(LibraryToolbarSeparator())
        .searchable(text: $model.searchText, placement: .toolbar, prompt: comments.isShown ? "Search comments" : cloud.isShown ? "Search uploads" : "Search captures")
        .toolbar { toolbar }
        .frame(minWidth: 860, minHeight: 540)
        .onAppear {
            AppActivationPolicy.enter()
            model.sortOrder = savedSort
            model.refresh()
            cloud.refresh()
            comments.refresh()
        }
        .onDisappear { AppActivationPolicy.leave() }
        .onWindowChange { window in
            libraryWindow = window
            PreviewWindowCaptureExclusion.shared.register(window: window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === libraryWindow {
                model.refresh()
                if cloud.isShown { cloud.refresh() }
                // The sidebar's unread count, whichever page is open. No timer: only here, on open and on ⌘R.
                comments.refresh()
            }
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
        if comments.isShown {
            CommentsLibraryPage(comments: comments)
        } else if cloud.isShown {
            CloudLibraryPage(cloud: cloud, layout: layout, cardWidth: cardWidth)
        } else if !model.hasLoaded {
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
                cardWidth: cardWidth, selection: $model.selection, isBusy: model.isBusy,
                cell: { [layout] item, selected, onTitleFrame in
                    AnyView(LibraryCellContent(item: item, layout: layout, selected: selected, onTitleFrame: onTitleFrame))
                },
                menu: { [model] in CaptureLibraryAction.menu(selected: $0, perform: model.perform) },
                onAction: model.perform)
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
            .compactMap { action, name in
                CaptureHotkeyPreferences.shortcut(for: action).map { $0.displayTokens.joined() + "\u{00A0}" + name }
            }
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
            .disabled(ScreenRecordingManager.shared.isActive || ScrollingCapturePresenter.shared.isRunning)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let title = model.operationTitle {
                ProgressView().controlSize(.mini)
                Text(title)
            } else if comments.isShown {
                let count = comments.visibleComments.count
                Text("\(count) \(count == 1 ? "comment" : "comments")")
                if !comments.selection.isEmpty { Text("· \(comments.selection.count) selected") }
                if !comments.deletingIDs.isEmpty { Text("· Deleting…") }
            } else if cloud.isShown, let fetch = cloud.previewFetch {
                ProgressView(value: fetch.total).controlSize(.mini).frame(width: 60)
                Text(fetch.title)
                Button("Stop Downloading", systemImage: "xmark.circle.fill") { cloud.cancelPreview() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Stop downloading")
            } else if cloud.isShown {
                let count = cloud.visibleUploads.count
                Text("\(count) \(count == 1 ? "upload" : "uploads")")
                if !cloud.selection.isEmpty { Text("· \(cloud.selection.count) selected") }
                if !cloud.deletingIDs.isEmpty { Text("· Deleting…") }
            } else {
                Text("\(model.visibleItems.count) \(model.visibleItems.count == 1 ? "capture" : "captures")")
                if !model.selection.isEmpty { Text("· \(model.selection.count) selected") }
            }
            Spacer()
            if comments.isShown ? comments.isLoading : cloud.isShown ? cloud.isLoading : model.isLoading {
                ProgressView().controlSize(.mini)
                    .help(comments.isShown ? "Refreshing comments" : cloud.isShown ? "Refreshing uploads" : "Refreshing Library")
            }
            if layout == .grid, !comments.isShown {
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
        // 20, not a DS step: it lines the count up with the toolbar title above.
        .padding(.horizontal, 20)
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
                    .disabled(ScreenRecordingManager.shared.isActive || ScrollingCapturePresenter.shared.isRunning)
            } label: { Label("New Capture", systemImage: "plus") }
            .help("New capture")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $layout) {
                Label("Grid View", systemImage: "square.grid.2x2").tag(CaptureLibraryLayout.grid).help("Grid view")
                Label("List View", systemImage: "list.bullet").tag(CaptureLibraryLayout.list).help("List view")
            }
            .labelStyle(.iconOnly)
            .pickerStyle(.segmented)
            // Comments are always a list.
            .disabled(comments.isShown)
            .help("Switch between grid and list")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $model.sortOrder) {
                    ForEach(CaptureLibrarySort.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    if comments.isShown { comments.refresh() } else if cloud.isShown { cloud.refresh() } else { model.refresh() }
                }
                    .keyboardShortcut("r", modifiers: .command)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .help("Sort captures")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) {
            if comments.isShown { commentActions } else if cloud.isShown { cloudActions } else { captureActions }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Button { inspectorVisible.toggle() } label: {
                Label(inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// Comments open on their share page; there's nothing to preview or edit.
    @ViewBuilder private var commentActions: some View {
        Menu {
            ForEach(Array(comments.menuItems().enumerated()), id: \.offset) { _, item in
                if item.startsGroup { Divider() }
                Button(item.title, action: item.perform).disabled(!item.isEnabled)
            }
        } label: { Label("Actions", systemImage: "ellipsis.circle") }
        .disabled(comments.selection.isEmpty)
        .help("Comment actions")
    }

    /// Uploads are final, so the Cloud page has no Edit.
    @ViewBuilder private var cloudActions: some View {
        Button { cloud.quickLook() } label: { Label("Quick Look", systemImage: "eye") }
            .disabled(cloud.selection.isEmpty)
            .help("Quick Look (Space)")
        Menu {
            ForEach(Array(cloud.menuItems().enumerated()), id: \.offset) { _, item in
                if item.startsGroup { Divider() }
                Button(item.title, action: item.perform).disabled(!item.isEnabled)
            }
        } label: { Label("Actions", systemImage: "ellipsis.circle") }
        .disabled(cloud.selection.isEmpty)
        .help("Upload actions")
    }

    @ViewBuilder private var captureActions: some View {
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
}

/// The editor's chrome colour behind a sidebar or inspector column, so the
/// columns and the toolbar read as one flat surface.
private struct LibrarySidebarSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background {
                    WorkspaceChrome.background.ignoresSafeArea(.container)
                }
        } else {
            content
        }
    }
}

/// The browser's ground: the editor's dotted workspace behind the grid and
/// the empty pages; the list keeps the chrome colour, because dots between
/// its full-width rows read as noise. Decorative only: the dots never take
/// clicks.
private struct LibraryBrowserSurface: ViewModifier {
    let showsDots: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27.0, *), showsDots {
            content.background { AnnotationEditorWorkspaceBackground().allowsHitTesting(false) }
        } else {
            content
        }
    }
}

/// Straight hairlines between the browser and the sidebar and inspector. The
/// columns share one chrome colour, so in the list nothing else divides them.
/// They stay below the toolbar, which runs unbroken across the window.
/// From 27.2 the split view draws its own dividers there (on 27.0.1 they're
/// clear), so these step aside rather than double them.
private struct LibraryColumnSeparators: ViewModifier {
    let leading: Bool
    let trailing: Bool
    @Environment(\.displayScale) private var displayScale

    @ViewBuilder
    func body(content: Content) -> some View {
        // ponytail: 27.1 unchecked (only 27.0.1 and 27.2 seen); move the
        // cut-off if 27.1 shows doubled or missing lines.
        if #available(macOS 27.2, *) {
            content
        } else if #available(macOS 27.0, *) {
            content
                .overlay(alignment: .leading) { if leading { line } }
                .overlay(alignment: .trailing) { if trailing { line } }
        } else {
            content
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1 / displayScale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The system's line under the toolbar, the one the editor shows. With the
/// toolbar background visible it runs over the browser and inspector; a hard
/// top scroll edge turns it on over the sidebar too.
private struct LibraryToolbarSeparator: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

/// The chrome colour behind the detail column. The toolbar keeps its own
/// background, as in the editor, so the system draws its line and keeps the
/// inspector's divider out of it. Backgrounds around `.inspector` keep the
/// safe area; clips don't.
private struct LibraryWindowSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27.0, *) {
            content
                .background { WorkspaceChrome.background.ignoresSafeArea() }
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            content
        }
    }
}

enum CaptureLibrarySidebarSelection: Hashable {
    case kind(CaptureLibraryFilter)
    case cloud
    case comments
    case tag(String)
}
