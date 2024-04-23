/// A type that determines if a document may be shared with a peer
public protocol ShareAuthorizing: Sendable {
    /// Returns a Boolean value that indicates whether a document may be shared.
    /// - Parameters:
    ///   - peer: The peer to potentially share with
    ///   - docId: The document Id to share
    func share(peer: PEER_ID, docId: DocumentId) async -> Bool
}

/// A type that encapsulates the logic to choose if a repository shares a document.
public struct SharePolicy: ShareAuthorizing, Sendable {
    /// Returns a Boolean value that indicates whether a document may be shared.
    /// - Parameters:
    ///   - peer: The peer to potentially share with
    ///   - docId: The document Id to share
    public func share(peer: PEER_ID, docId: DocumentId) async -> Bool {
        await shareCheck(peer, docId)
    }

    // let msgResponse: @Sendable (SyncV1Msg) async -> SyncV1Msg?
    let shareCheck: @Sendable (_ peer: PEER_ID, _ docId: DocumentId) async -> Bool

    /// Create a new share policy that determines a repo's share authorization logic with a closure that you provide.
    /// - Parameter closure: A closure that accepts a peer ID and a document ID and returns a Boolean value that
    /// indicates if the document may be shared with peers requesting it.
    public init(
        _ closure: @Sendable @escaping (_ peer: PEER_ID, _ docId: DocumentId) async -> Bool
    ) {
        self.shareCheck = closure
    }

    /// A policy that always shares documents.
    public static let agreeable = SharePolicy { _, _ in
        true
    }

    /// A policy that never shares documents.
    public static let readonly = SharePolicy { _, _ in
        false
    }
}
