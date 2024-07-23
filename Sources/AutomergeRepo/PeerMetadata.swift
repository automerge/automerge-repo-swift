internal import Foundation

// ; Metadata sent in either the join or peer message types
// peer_metadata = {
//    ; The storage ID of this peer
//    ? storageId: storage_id,
//    ; Whether the sender expects to connect again with this storage ID
//    isEphemeral: bool
// }

/// A type that represents metadata associated with the storage capabilities of a remote peer.
public struct PeerMetadata: Hashable, Sendable, Codable, CustomDebugStringConvertible {
    /// The ID of the peer's storage
    ///
    /// Multiple peers can technically share the same persistent storage.
    public var storageId: STORAGE_ID?

    /// A Boolean value that indicates any data sent to this peer is ephemeral.
    ///
    /// Typically, this means that the peer doesn't have any local persistent storage.
    public var isEphemeral: Bool

    /// Creates a new instance of peer metadata
    /// - Parameters:
    ///   - storageId: An optional storage ID
    ///   - isEphemeral: A Boolean value that indicates any data sent to this peer is ephemeral
    public init(storageId: STORAGE_ID? = nil, isEphemeral: Bool) {
        self.storageId = storageId
        self.isEphemeral = isEphemeral
    }

    /// A description of the metadata
    public var debugDescription: String {
        "[storageId: \(storageId ?? "nil"), ephemeral: \(isEphemeral)]"
    }
}
