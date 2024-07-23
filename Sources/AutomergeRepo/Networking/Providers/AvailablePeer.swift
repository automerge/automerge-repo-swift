public import Network

/// A type that represents a peer available on the Peer to Peer (Bonjour) network.
public struct AvailablePeer: Identifiable, Sendable {
    /// The ID of the peer
    public let peerId: String
    /// The ID endpoint where the peer is available
    public let endpoint: NWEndpoint
    /// The name broadcast for that peer
    public let name: String
    /// The stable identity of the peer
    public var id: String {
        peerId
    }
}

extension AvailablePeer: Hashable {}

extension AvailablePeer: Comparable {
    /// Compares two available peers to provide consistent ordering by name.
    /// - Parameters:
    ///   - lhs: The first available peer to compare
    ///   - rhs: The second available peer to compare.
    public static func < (lhs: AvailablePeer, rhs: AvailablePeer) -> Bool {
        lhs.name < rhs.name
    }
}

extension AvailablePeer: CustomDebugStringConvertible {
    public var debugDescription: String {
        "\(name) [\(peerId)] at \(endpoint.debugDescription)"
    }
}
