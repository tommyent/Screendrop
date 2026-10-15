import SwiftUI

/// Present as a sheet with `FreeToUseMusicPicker(setBackgroundMusic: model.setBackgroundMusic)`.
struct FreeToUseMusicPicker: View {
    let setBackgroundMusic: (_ fileURL: URL, _ displayName: String, _ credit: String?, _ startOffset: TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = FreeToUseMusicPickerModel()
    @State private var categoryRetry = 0
    @State private var tracksRetry = 0
    @FocusState private var searchFocused: Bool

    private struct Request: Hashable {
        let browse: FreeToUseMusicAPI.Browse
        let retry: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Find music").font(.headline)
                    Spacer()
                    Button("Done") { close() }
                        .keyboardShortcut(.cancelAction)
                }
                TextField("Search music", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { model.search() }
                categoryChips
                if let message = model.categoriesError {
                    inlineError(message) { categoryRetry += 1 }
                }
            }
            .padding(16)
            Divider()
            results
            Divider()
            Text("Free for personal social videos with the credit line; not client or commercial work.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 820, minHeight: 550, idealHeight: 640, maxHeight: 800)
        .onAppear { searchFocused = true }
        .task(id: categoryRetry) { await model.loadCategories() }
        .task(id: Request(browse: model.browse, retry: tracksRetry)) { await model.loadTracks() }
        .task(id: model.searchText) {
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            model.search()
        }
        .onDisappear { model.close() }
    }

    private var categoryChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                chip("All", selected: model.browse == .all) { model.select(nil) }
                if case .search(let query) = model.browse {
                    Text("Results for \(query)")
                        .font(.subheadline)
                        .lineLimit(1)
                        .help(query)
                }
            }
            ForEach(["Mood", "Genre", "Video"], id: \.self) { group in
                HStack(spacing: 8) {
                    Text(group)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(model.categories.filter { $0.type == group }) { category in
                                chip(category.name, selected: model.browse == .category(category)) {
                                    model.select(category)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityLabel("\(group) categories")
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(selected ? Color.accentColor : Color.secondary)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.tracks) { track in
                    FreeToUseMusicRow(track: track, preview: model.preview,
                                      isDownloading: model.downloadingID == track.id,
                                      downloadError: model.failedDownloadID == track.id ? model.downloadError : nil) {
                        model.use(track, setBackgroundMusic: setBackgroundMusic) { close() }
                    }
                    .disabled(model.downloadingID != nil && model.downloadingID != track.id)
                    Divider()
                }
                if model.isLoading {
                    ProgressView("Loading music…").padding(24)
                } else if let message = model.tracksError {
                    inlineError(message) {
                        if model.nextOffset != nil { model.loadMore() }
                        else { tracksRetry += 1 }
                    }
                    .padding(16)
                } else if model.nextOffset != nil {
                    Button("Load more") { model.loadMore() }.padding(16)
                } else if model.tracks.isEmpty {
                    Text("No free tracks match. Try another word or category.")
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
            }
        }
    }

    private func inlineError(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Retry", action: retry).controlSize(.small)
        }
    }

    private func close() {
        model.close()
        dismiss()
    }
}

private struct FreeToUseMusicRow: View {
    let track: FreeToUseMusicAPI.Track
    @Bindable var preview: FreeToUseMusicPreview
    let isDownloading: Bool
    let downloadError: String?
    let use: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(preview.trackID == track.id && preview.isPlaying ? "Pause \(track.title)" : "Preview \(track.title)",
                       systemImage: preview.trackID == track.id && preview.isPlaying ? "pause.fill" : "play.fill") {
                    preview.toggle(track)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .disabled(isDownloading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                    Text([track.artist, track.firstTags].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(clock(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if isDownloading {
                    ProgressView().controlSize(.small).accessibilityLabel("Downloading \(track.title)")
                } else {
                    Button(downloadError == nil ? "Use" : "Retry", action: use)
                        .accessibilityLabel(downloadError == nil ? "Use \(track.title)" : "Retry downloading \(track.title)")
                }
            }
            if preview.trackID == track.id {
                HStack {
                    Slider(value: $preview.scrubPosition, in: 0...track.duration) {
                        Text("Scrub through \(track.title)")
                    } onEditingChanged: { editing in
                        preview.isScrubbing = editing
                    }
                    .accessibilityValue("\(clock(preview.position)) of \(clock(track.duration))")
                    Text("\(clock(preview.position)) / \(clock(track.duration))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let error = preview.error {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { preview.retry(track) }.controlSize(.small)
                    }
                }
            }
            if let downloadError {
                Text(downloadError).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
