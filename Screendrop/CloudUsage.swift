import Foundation
import SwiftUI

/// What the Worker's bucket holds, as Bearer GET /api/usage reports it
/// (sd-irc). Listed from R2, so video sidecars, branding and anything a
/// failed upload left behind count too.
nonisolated struct CloudUsage: Decodable, Equatable, Sendable {
    let bytes: Int64
    let objects: Int
    /// False when the bucket held more objects than one request lists;
    /// `bytes` is then a lower bound.
    let complete: Bool

    /// Green while there's room, amber from 80% of the threshold, red at it.
    enum Level: Equatable {
        case normal, nearlyFull, full
    }

    static func level(bytes: Int64, threshold: Int64) -> Level {
        guard threshold > 0 else { return .full }
        let fraction = Double(bytes) / Double(threshold)
        return fraction >= 1 ? .full : fraction >= 0.8 ? .nearlyFull : .normal
    }

    /// "1.2 GB of 5 GB used".
    static func summary(bytes: Int64, threshold: Int64, complete: Bool) -> String {
        let used = bytes.formatted(.byteCount(style: .file))
        let limit = threshold.formatted(.byteCount(style: .file))
        return complete ? "\(used) of \(limit) used" : "At least \(used) of \(limit) used"
    }

    static func request(workerBase: String, token: String) -> URLRequest? {
        guard let url = URL(string: workerBase + "/api/usage"), url.host != nil else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The request on its own, so a check can run it against a local Worker
    /// without the keychain. Nil when the Worker predates GET /api/usage.
    static func fetch(workerBase: String, token: String) async throws -> CloudUsage? {
        guard let request = request(workerBase: workerBase, token: token) else {
            throw CloudUploadError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudUploadError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw CloudUploadError.serverError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(CloudUsage.self, from: data)
    }
}

enum CloudStoragePreferences {
    static let thresholdGBKey = "cloudStorageThresholdGB"
    static let defaultThresholdGB = 5.0

    /// The threshold in bytes, decimal gigabytes as Finder counts them.
    static func thresholdBytes(gigabytes: Double) -> Int64 {
        Int64(max(0.1, gigabytes) * 1_000_000_000)
    }
}

/// The Cloud page's storage bar: green, then amber from 80% of the
/// threshold and red at it, with how much is used under it. A warning
/// only; nothing is blocked or deleted.
struct CloudUsageBar: View {
    let usage: CloudUsage
    @AppStorage(CloudStoragePreferences.thresholdGBKey) private var thresholdGB = CloudStoragePreferences.defaultThresholdGB

    var body: some View {
        let threshold = CloudStoragePreferences.thresholdBytes(gigabytes: thresholdGB)
        let fraction = min(1, Double(usage.bytes) / Double(threshold))
        let summary = CloudUsage.summary(bytes: usage.bytes, threshold: threshold, complete: usage.complete)
        VStack(alignment: .leading, spacing: 4) {
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(color(for: CloudUsage.level(bytes: usage.bytes, threshold: threshold)))
                            .frame(width: max(6, proxy.size.width * fraction))
                    }
                }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: 260, alignment: .leading)
        .help("Cloud storage, against the threshold in Settings › Cloud")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cloud storage")
        .accessibilityValue(summary)
    }

    private func color(for level: CloudUsage.Level) -> Color {
        switch level {
        case .normal: .green
        case .nearlyFull: .orange
        case .full: .red
        }
    }
}

/// Settings › Cloud's storage threshold for the Library's bar.
struct CloudStorageSettingsSection: View {
    @AppStorage(CloudStoragePreferences.thresholdGBKey) private var thresholdGB = CloudStoragePreferences.defaultThresholdGB

    var body: some View {
        Section {
            LabeledContent("Storage threshold") {
                HStack(spacing: 4) {
                    TextField("Storage threshold", value: $thresholdGB, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("GB")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("The Library's Cloud page shows how much your Worker stores against this. Its bar turns amber at 80% and red when full; nothing is blocked or deleted. Cloudflare R2's free tier is 10 GB.")
        }
        .onChange(of: thresholdGB) { _, value in
            // A threshold of zero or less would always read as full.
            if value < 0.1 { thresholdGB = 0.1 }
        }
    }
}
