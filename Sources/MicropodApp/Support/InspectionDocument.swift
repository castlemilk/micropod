import Foundation

/// A single formatted payload with inexpensive slices for visible rows.
/// Substrings share the payload's storage instead of retaining a second copy
/// of every line. Formatting and indexing stay off the UI actor.
struct InspectionDocument: Sendable {
    let text: String
    let lines: [Substring]

    init(data: Data) throws {
        try Task.checkCancellation()
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        try Task.checkCancellation()
        let formatted = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        try Task.checkCancellation()
        text = String(decoding: formatted, as: UTF8.self)
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        try Task.checkCancellation()
    }

    static func format(_ data: Data) async throws -> InspectionDocument {
        let worker = Task.detached(priority: .utility) { try InspectionDocument(data: data) }
        let document = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return document
    }
}
