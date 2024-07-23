public import Foundation

/// A type that represents a snapshot of the current state of a peer-to-peer network connection.
public struct PeerConnectionInfo: Sendable, Identifiable, CustomStringConvertible {
    /// A single-line string representation of the connection information.
    public var description: String {
        var str = ""
        if initiated {
            str.append(" -> ")
        } else {
            str.append(" <- ")
        }
        if let meta = peerMetadata {
            str.append("\(peerId),\(meta)")
        } else {
            str.append("\(peerId),nil")
        }
        if peered {
            str.append(" [ready]")
        } else {
            str.append(" [pending]")
        }
        return str
    }

    /// The peer ID of the remote end of this connection.
    public let peerId: PEER_ID
    /// The peer metadata, if any, of the remote end of this connection.
    public let peerMetadata: PeerMetadata?

    // additional metadata about the connection that's useful for UI displays

    /// The endpoint of the remote end of the connection, represented as a string.
    public let endpoint: String
    /// A Boolean value that indicates if this provider initiated the connection.
    public let initiated: Bool
    /// A Boolean value that indicates the connection is fully established and ready to use.
    public let peered: Bool
    /// The stable identifier for this snapshot.
    public let id: UUID

    /// Create a new peer connection information snapshot.
    /// - Parameters:
    ///   - peerId: The peer ID of the remote end of this connection.
    ///   - peerMetadata: The peer metadata, if any, of the remote end of this connection.
    ///   - endpoint: The endpoint of the remote end of the connection, represented as a string.
    ///   - initiated: A Boolean value that indicates if this provider initiated the connection.
    ///   - peered: A Boolean value that indicates the connection is fully established and ready to use.
    public init(peerId: PEER_ID, peerMetadata: PeerMetadata?, endpoint: String, initiated: Bool, peered: Bool) {
        self.peerId = peerId
        self.peerMetadata = peerMetadata
        self.endpoint = endpoint
        self.initiated = initiated
        self.peered = peered
        self.id = UUID()
    }
}

extension PeerConnectionInfo: Hashable {}

extension PeerConnectionInfo: Comparable {
    /// Compares two snapshots to provide consistent ordering for snapshots.
    /// - Parameters:
    ///   - lhs: The first network information snapshot to compare
    ///   - rhs: The second network information snapshot to compare.
    public static func < (lhs: PeerConnectionInfo, rhs: PeerConnectionInfo) -> Bool {
        lhs.peerId < rhs.peerId
    }
}
