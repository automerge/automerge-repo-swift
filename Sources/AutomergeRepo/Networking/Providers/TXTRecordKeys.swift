/// A type that provides type-safe strings for TXTRecord publication of peers over Bonjour
public enum TXTRecordKeys: Sendable {
    /// The peer identifier.
    public static let peer_id = "peer_id"
    /// The human-readable name for the peer.
    public static let name = "name"
}
