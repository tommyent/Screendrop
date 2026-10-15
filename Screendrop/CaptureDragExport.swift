import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct CaptureDragExport: Transferable, Sendable {
    let url: URL
    let isVideo: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { item in
            await MainActor.run { StudioProjectRegistry.shared.flushDrafts() }
            return SentTransferredFile(try await RecordingDeliverable.resolve(for: item.url))
        }
        .exportingCondition { $0.isVideo }
        ProxyRepresentation { $0.url }
            .exportingCondition { !$0.isVideo }
    }
}
