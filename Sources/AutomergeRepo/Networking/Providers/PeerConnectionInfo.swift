public struct PeerConnectionInfo: Sendable, Identifiable, CustomStringConvertible {
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

    public let peerId: PEER_ID
    public let peerMetadata: PeerMetadata?
    // additional metadata about the connection that's useful for UI displays
    public let endpoint: String
    public let initiated: Bool
    public let peered: Bool

    public init(peerId: PEER_ID, peerMetadata: PeerMetadata?, endpoint: String, initiated: Bool, peered: Bool) {
        self.peerId = peerId
        self.peerMetadata = peerMetadata
        self.endpoint = endpoint
        self.initiated = initiated
        self.peered = peered
    }

    public var id: String {
        peerId
    }
}

extension PeerConnectionInfo: Hashable {}

extension PeerConnectionInfo: Comparable {
    public static func < (lhs: PeerConnectionInfo, rhs: PeerConnectionInfo) -> Bool {
        lhs.peerId < rhs.peerId
    }
}
