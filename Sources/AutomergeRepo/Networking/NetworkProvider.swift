// import AsyncAlgorithms

// import protocol Combine.Publisher
import Automerge

// https://github.com/automerge/automerge-repo/blob/main/packages/automerge-repo/src/network/NetworkAdapterInterface.ts

/// A type that is responsible for establishing, and maintaining, one or more network connection for a repository.
///
/// Types conforming to `NetworkProvider` are responsible for the setup and initial handshake of network
/// connections to other peers.
/// They provide a means to send messages to other peers, and through a delegate provides messages and updates
/// when connections are made, disconnected, and messages are received from connected peers.
/// The delegate is responsible for processing and responding to sync, gossip, and other messages appropriately.
///
/// A NetworkProvider can initiate or listen for connections, or support both.
///
/// The expected behavior when a network provider initiates a connection:
///
/// - After the underlying transport connection is established due to a call to `connect`, the emit
/// ``NetworkAdapterEvents/ready(payload:)``, which includes a payload that provides information about the peer that is now connected.
/// - After the connection is established, send a ``SyncV1Msg/join(_:)`` message to request peering.
/// - When the NetworkAdapter receives a ``SyncV1Msg/peer(_:)`` message, emit
/// ``NetworkAdapterEvents/peerCandidate(payload:)``.
/// - If the provider receives a message other than `peer`, terminate the connection and emit ``NetworkAdapterEvents/close``.
/// - For any other message, emit it to the delegate using ``NetworkAdapterEvents/message(payload:)``.
/// - When a transport connection is closed, emit ``NetworkAdapterEvents/peerDisconnect(payload:)``.
/// - When `disconnect` is invoked on a network provider, send a ``SyncV1Msg/leave(_:)`` message then terminate
/// the connection, and emit ``NetworkAdapterEvents/close``.
///
/// A connecting transport may optionally enable automatic reconnection on connection failure. 
/// If the provider supports configurable reconnection logic, it should be configured with a `configure`
/// call with the relevant configuration type for the network provider.
///
/// The expected behavior when listening for, and responding to, an incoming connection:
///
/// - When a connection is established, emit ``NetworkAdapterEvents/ready(payload:)``.
/// - When the transport receives a `join` message, verify that the protocols being requested are compatible. 
/// If it is not, return an ``SyncV1Msg/error(_:)`` message, close the connection, and emit ``NetworkAdapterEvents/close``.
/// - When any other message is received, emit it using ``NetworkAdapterEvents/message(payload:)``.
/// - When the transport receives a `leave` message, close the connection and emit ``NetworkAdapterEvents/close``.
/// 
@AutomergeRepo
public protocol NetworkProvider: Sendable {
    /// A string that represents the name of the network provider
    var name: String { get }

    /// A list of all active, peered connections that the provider is maintaining.
    ///
    /// For an outgoing connection, this is typically a single connection.
    /// For a listening connection, this could be quite a few.
    var peeredConnections: [PeerConnectionInfo] { get }

    /// A type that represents the endpoint that the provider can connect with.
    ///
    /// For example, it could be `URL`, `NWEndpoint` for a Bonjour network, or a custom type.
    associatedtype NetworkConnectionEndpoint: Sendable

    /// Initiate an outgoing connection.
    func connect(to: NetworkConnectionEndpoint) async throws // aka "activate"

    /// Disconnect and terminate any existing connection.
    func disconnect() async // aka "deactivate"

    /// Requests the network transport to send a message.
    /// - Parameter message: The message to send.
    /// - Parameter to: An option peerId to identify the recipient for the message. If nil, the message is sent to all
    /// connected peers.
    func send(message: SyncV1Msg, to: PEER_ID?) async

    /// Set the delegate for the peer to peer provider.
    /// - Parameters:
    ///   - delegate: The delegate instance.
    ///   - peerId: The peer ID to use for the peer to peer provider.
    ///   - metadata: The peer metadata, if any, to use for the peer to peer provider.
    ///
    /// This is typically called when the delegate adds the provider, and provides this network
    /// provider with a peer ID and associated metadata, as well as an endpoint that receives
    /// Automerge sync protocol sync message and network events.
    func setDelegate(_ delegate: any NetworkEventReceiver, as peer: PEER_ID, with metadata: PeerMetadata?)
}
