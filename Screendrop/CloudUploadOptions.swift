//
//  CloudUploadOptions.swift
//  Screendrop
//
//  The title, link expiry and comment choices offered right before a
//  manual cloud upload. Auto-upload (after-capture, no user interaction)
//  skips this entirely: no expiry, and the remembered comment toggles.
//

import SwiftUI

struct CloudUploadOptions: Sendable {
    var title: String
    var socialEnabled: Bool
    var expiry = CloudExpiry.never
    var allowAnonymousComments = true

    /// `nil` title means "let the worker fall back to the filename (or,
    /// for recordings, the auto-generated 'Screen Recording - …' title)".
    var trimmedTitleOrNil: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// How long a new share link lasts. Expired links stop working, and the
/// Worker deletes them daily.
nonisolated enum CloudExpiry: Int, CaseIterable, Identifiable, Sendable {
    case never = 0, day = 1, week = 7, month = 30

    var id: Int { rawValue }
    var title: String { self == .never ? "Never" : rawValue == 1 ? "1 day" : "\(rawValue) days" }

    /// When a link made at `now` stops working; nil for never.
    func date(from now: Date = .now) -> Date? {
        self == .never ? nil : now.addingTimeInterval(Double(rawValue) * 86_400)
    }
}

/// Remembers the last-chosen "allow comments & likes" toggle across
/// uploads (including background auto-uploads, which never show the
/// popover) so the common case doesn't require re-deciding every time.
enum CloudUploadPreferences {
    private static let socialEnabledKey = "cloudUploadDefaultSocialEnabled"

    static var lastSocialEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: socialEnabledKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: socialEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: socialEnabledKey) }
    }

    private static let anonymousCommentsKey = "cloudUploadDefaultAnonymousComments"

    /// On unless turned off, as the Worker's own default.
    static var lastAnonymousComments: Bool {
        get { UserDefaults.standard.object(forKey: anonymousCommentsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: anonymousCommentsKey) }
    }
}

/// Small popover form shown from an upload/share button: a title field
/// (prefilled with a suggested default, editable), when the link expires,
/// and whether comments + likes are on and open to anonymous visitors.
/// Confirming remembers the comment toggles as the defaults for next
/// time; the expiry starts at Never every time.
struct CloudUploadOptionsPopover: View {
    let suggestedTitle: String
    let onConfirm: (CloudUploadOptions) -> Void

    @State private var title: String
    @State private var socialEnabled = CloudUploadPreferences.lastSocialEnabled
    @State private var expiry = CloudExpiry.never
    @State private var allowAnonymousComments = CloudUploadPreferences.lastAnonymousComments
    @Environment(\.dismiss) private var dismiss

    init(suggestedTitle: String = "", onConfirm: @escaping (CloudUploadOptions) -> Void) {
        self.suggestedTitle = suggestedTitle
        self.onConfirm = onConfirm
        _title = State(initialValue: suggestedTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share Options")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Title", text: $title, prompt: Text("Untitled"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
            }

            HStack {
                Text("Link expires")
                Spacer()
                Picker("Link expires", selection: $expiry) {
                    ForEach(CloudExpiry.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            HStack {
                Text("Allow comments & likes")
                Spacer()
                Toggle("Allow comments & likes", isOn: $socialEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            HStack {
                Text("Allow anonymous comments")
                Spacer()
                Toggle("Allow anonymous comments", isOn: $allowAnonymousComments)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .disabled(!socialEnabled)
            .foregroundStyle(socialEnabled ? .primary : .secondary)
            .help("Visitors can comment without signing in")

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Upload") {
                    CloudUploadPreferences.lastSocialEnabled = socialEnabled
                    CloudUploadPreferences.lastAnonymousComments = allowAnonymousComments
                    let options = CloudUploadOptions(title: title, socialEnabled: socialEnabled, expiry: expiry,
                                                     allowAnonymousComments: allowAnonymousComments)
                    dismiss()
                    onConfirm(options)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Wraps any trigger content in a button that opens `CloudUploadOptionsPopover`
/// before firing `onUpload`. Drop-in replacement for a plain
/// `Button(action: onUpload) { ... }` at a manual upload/share call site.
struct CloudUploadButton<Label: View>: View {
    let suggestedTitle: String
    let onUpload: (CloudUploadOptions) -> Void
    @ViewBuilder let label: () -> Label

    @State private var showingOptions = false

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            label()
        }
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            CloudUploadOptionsPopover(suggestedTitle: suggestedTitle, onConfirm: onUpload)
        }
    }
}
