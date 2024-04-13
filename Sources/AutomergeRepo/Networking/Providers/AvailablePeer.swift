import Network

public struct AvailablePeer: Identifiable, Sendable {
    public let peerId: String
    public let endpoint: NWEndpoint
    public let name: String
    public var id: String {
        peerId
    }
}

extension AvailablePeer: Hashable {}

extension AvailablePeer: Comparable {
    public static func < (lhs: AvailablePeer, rhs: AvailablePeer) -> Bool {
        lhs.name < rhs.name
    }
}
