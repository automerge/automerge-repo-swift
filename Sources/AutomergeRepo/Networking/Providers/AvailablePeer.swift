import Network

public struct AvailablePeer: Sendable {
    public let peerId: PEER_ID
    public let endpoint: NWEndpoint
    public let name: String
}

