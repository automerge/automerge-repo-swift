/// Describes the network events that a network provider sends to its delegate.
///
/// The ``Repo`` and its internal systems are responsible for responding to these events.
/// Send these events when new connections are established,
/// peers are added or removed on a connection, of for ``SyncV1Msg`` messages that are not
/// related to establishing the connection.
public enum NetworkAdapterEvents: Sendable, CustomDebugStringConvertible {
    /// A description of the event.
    public var debugDescription: String {
        switch self {
        case let .ready(payload):
            "NetworkAdapterEvents.ready[\(payload)]"
        case .close:
            "NetworkAdapterEvents.close[]"
        case let .peerCandidate(payload):
            "NetworkAdapterEvents.peerCandidate[\(payload)]"
        case let .peerDisconnect(payload):
            "NetworkAdapterEvents.peerDisconnect[\(payload)]"
        case let .message(payload):
            "NetworkAdapterEvents.message[\(payload)]"
        }
    }
    
    /// The information associated with an individual peer being disconnected from a network provider.
    public struct PeerDisconnectPayload: Sendable, CustomStringConvertible {
        /// A string representation of the payload.
        public var description: String {
            "\(peerId)"
        }

        // handled by Repo, relevant to Sync
        /// The peer that disconnected.
        public let peerId: PEER_ID
        
        /// Creates a new payload identifying the peer that disconnected.
        /// - Parameter peerId: The peer that disconnected.
        public init(peerId: PEER_ID) {
            self.peerId = peerId
        }
    }

    /// A network event that indicates a network connection has been established and successfully handshaked.
    ///
    /// This message is sent by both listening (passive) and initiating (active) connections.
    case ready(payload: PeerConnectionInfo) //
    /// A network event that indicates a request to close a connection.
    case close // handled by Repo, relevant to sync
    /// A network event that indicates that a listening network has received a connection with a proposed peer,
    /// but the handshake and any authorization process is not yet complete.
    case peerCandidate(payload: PeerConnectionInfo)
    /// A network event that indicates a connection closed.
    case peerDisconnect(payload: PeerDisconnectPayload) // send when a peer connection terminates
    /// A network event that passes a protocol message into the repo.
    ///
    /// The messages sent should be a subset of ``SyncV1Msg``. The provider should accept any message,
    /// but the handshake protocol messages (``SyncV1Msg/join(_:)``, ``SyncV1Msg/peer(_:)``) and
    /// ``SyncV1Msg/unknown(_:)`` are unexpected.
    case message(payload: SyncV1Msg) // handled by Sync
}

// network connection overview:
// - connection established
// - initiating side sends "join" message
// - receiving side send "peer" message
// ONLY after peer message is received is the connection considered valid

// for an outgoing connection:
// - network is ready for action
// - connect(to: SOMETHING)
// - when it receives the "peer" message, it's ready for ongoing work

// for an incoming connection:
// - network is ready for action
// - remove peer opens a connection, we receive a "join" message
// - (peer candidate is known at that point)
// - if all is good (version matches, etc) then we send "peer" message to acknowledge
// - after that, we're ready to process protocol messages
