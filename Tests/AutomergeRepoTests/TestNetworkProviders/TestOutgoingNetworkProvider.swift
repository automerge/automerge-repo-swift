import Automerge
import AutomergeRepo
import Foundation

public struct TestOutgoingNetworkConfiguration: Sendable, CustomDebugStringConvertible {
    let remotePeer: PEER_ID
    let remotePeerMetadata: PeerMetadata?
    let msgResponse: @Sendable (SyncV1Msg) async -> SyncV1Msg?

    public var debugDescription: String {
        "peer: \(remotePeer), metadata: \(remotePeerMetadata?.debugDescription ?? "none")"
    }

    init(
        remotePeer: PEER_ID,
        remotePeerMetadata: PeerMetadata?,
        msgResponse: @Sendable @escaping (SyncV1Msg) async -> SyncV1Msg
    ) {
        self.remotePeer = remotePeer
        self.remotePeerMetadata = remotePeerMetadata
        self.msgResponse = msgResponse
    }

    public static let simple: @Sendable (SyncV1Msg) async -> SyncV1Msg? = { msg in
        var doc = Document()
        var syncState = SyncState()
        let peerId: PEER_ID = "SIMPLE REMOTE TEST"
        let peerMetadata: PeerMetadata? = PeerMetadata(storageId: "SIMPLE STORAGE", isEphemeral: true)
        switch msg {
        case let .join(msg):
            return .peer(.init(
                senderId: peerId,
                targetId: msg.senderId,
                storageId: peerMetadata?.storageId,
                ephemeral: peerMetadata?.isEphemeral ?? false
            ))
        case .peer:
            return nil
        case .leave:
            return nil
        case .error:
            return nil
        case let .request(msg):
            // everything is always unavailable
            return .unavailable(.init(documentId: msg.documentId, senderId: peerId, targetId: msg.senderId))
        case let .sync(msg):
            do {
                try doc.receiveSyncMessage(state: syncState, message: msg.data)
                if let returnData = doc.generateSyncMessage(state: syncState) {
                    return .sync(.init(
                        documentId: msg.documentId,
                        senderId: peerId,
                        targetId: msg.senderId,
                        sync_message: returnData
                    ))
                }
            } catch {
                return .error(.init(message: error.localizedDescription))
            }
            return nil
        case .unavailable:
            return nil
        case .ephemeral:
            return nil // TODO: RESPONSE EXAMPLE
        case .remoteSubscriptionChange:
            return nil
        case .remoteHeadsChanged:
            return nil
        case .unknown:
            return nil
        }
    }
}

/// A Test network that operates in memory
///
/// Acts akin to an outbound connection - doesn't "connect" and trigger messages until you explicitly ask
@AutomergeRepo
public final class TestOutgoingNetworkProvider: NetworkProvider {
    public let name = "MockProvider"
    public var peeredConnections: [PeerConnectionInfo] = []

    public typealias NetworkConnectionEndpoint = String

    public nonisolated var debugDescription: String {
        "TestOutgoingNetworkProvider"
    }

    public nonisolated var description: String {
        "TestNetwork"
    }

    var delegate: (any NetworkEventReceiver)?

    var config: TestOutgoingNetworkConfiguration?
    var connected: Bool
    var messages: [SyncV1Msg] = []

    public typealias ProviderConfiguration = TestOutgoingNetworkConfiguration

    init() {
        connected = false
        delegate = nil
    }

    public func configure(_ config: TestOutgoingNetworkConfiguration) async {
        self.config = config
    }

    public var connectedPeer: PEER_ID? {
        get async {
            if let config, connected == true {
                return config.remotePeer
            }
            return nil
        }
    }

    public func connect(to somewhere: String) async throws {
        do {
            guard let config else {
                throw UnconfiguredTestNetwork()
            }
            let initialPeerConnection = PeerConnectionInfo(
                peerId: config.remotePeer,
                peerMetadata: config.remotePeerMetadata,
                endpoint: somewhere,
                initiated: true,
                peered: false
            )

            peeredConnections.append(initialPeerConnection)
            await delegate?.receiveEvent(
                event: .peerCandidate(
                    payload: initialPeerConnection
                )
            )
            try await Task.sleep(for: .milliseconds(250))
            let finalPeerConnection = PeerConnectionInfo(
                peerId: config.remotePeer,
                peerMetadata: config.remotePeerMetadata,
                endpoint: somewhere,
                initiated: true,
                peered: true
            )
            await delegate?.receiveEvent(
                event: .ready(
                    payload: finalPeerConnection
                )
            )
            connected = true

        } catch {
            connected = false
        }
    }

    public func disconnect() async {
        connected = false
    }

    public func ready() async -> Bool {
        connected
    }

    public func send(message: SyncV1Msg, to _: PEER_ID?) async {
        messages.append(message)
        if let response = await config?.msgResponse(message) {
            await delegate?.receiveEvent(event: .message(payload: response))
        }
    }

    public func receiveMessage(msg _: SyncV1Msg) async {
        // no-op on the receive, as all "responses" are generated by a closure provided
        // by the configuration of this test network provider.
    }

    public func setDelegate(
        _ delegate: any NetworkEventReceiver,
        as _: PEER_ID,
        with _: PeerMetadata?
    ) {
        self.delegate = delegate
    }

    // MARK: TESTING SPECIFIC API

    public func disconnectNow() async {
        guard let config else {
            fatalError("Attempting to disconnect an unconfigured testing network")
        }
        if connected {
            connected = false
            await delegate?.receiveEvent(event: .peerDisconnect(payload: .init(peerId: config.remotePeer)))
        }
    }

    public func messagesReceivedByRemotePeer() async -> [SyncV1Msg] {
        messages
    }

    /// WIPES TEST NETWORK AND ERASES DELEGATE SETTING
    public func resetTestNetwork() async {
        guard config != nil else {
            fatalError("Attempting to reset an unconfigured testing network")
        }
        connected = false
        messages = []
        delegate = nil
    }
}
