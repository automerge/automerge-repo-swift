import class Automerge.Document

/// A type that represents an Automerge Document with its identifier.
public struct DocHandle: Sendable {
    /// The ID of the document.
    public let id: DocumentId

    /// The Automerge document.
    public let doc: Document

    /// Creates a new DocHandle with the ID and document that you provide.
    /// - Parameters:
    ///   - id: the ID of the Document
    ///   - doc: the Automerge Document
    public init(id: DocumentId, doc: Document) {
        self.id = id
        self.doc = doc
    }
}
