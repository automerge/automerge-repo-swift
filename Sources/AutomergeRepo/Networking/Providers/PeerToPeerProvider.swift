import Foundation
import Network
import OSLog

#if os(iOS)
import UIKit // for UIDevice.name access
#endif

public actor PeerToPeerProvider: NetworkProvider {
    public typealias NetworkConnectionEndpoint = NWEndpoint

    public struct PeerToPeerProviderConfiguration: Sendable {
        let reconnectOnError: Bool
        let listening: Bool
        let autoconnect: Bool
        let peerName: String
        let passcode: String

        init(reconnectOnError: Bool, listening: Bool, peerName: String?, passcode: String, autoconnect: Bool? = nil) {
            self.reconnectOnError = reconnectOnError
            self.listening = listening
            if let auto = autoconnect {
                self.autoconnect = auto
            } else {
                #if os(iOS)
                self.autoconnect = true
                #elseif os(macOS)
                self.autoconnect = false
                #endif
            }
            if let name = peerName {
                self.peerName = name
            } else {
                self.peerName = Self.defaultSharingIdentity()
            }
            self.passcode = passcode
        }

        // MARK: default sharing identity

        public static func defaultSharingIdentity() -> String {
            let defaultName: String
            #if os(iOS)
            defaultName = UIDevice().name
            #elseif os(macOS)
            defaultName = Host.current().localizedName ?? "Automerge User"
            #endif
            return UserDefaults.standard
                .string(forKey: UserDefaultKeys.publicPeerName) ?? defaultName
        }
    }

    /// A wrapper around PeerToPeer connection that holds additional metadata about the connection
    /// relevant for the PeerToPeer provider, exposing a copy of its endpoint and latest updated Peering
    /// state so that it can be used from synchronous calls inside this actor.
    struct ConnectionHolder: Sendable {
        var connection: PeerToPeerConnection
        var initiated: Bool
        var peered: Bool
        var endpoint: NWEndpoint
        var peerId: PEER_ID?
        var peerMetadata: PeerMetadata?

        init(
            connection: PeerToPeerConnection,
            initiated: Bool,
            peered: Bool,
            endpoint: NWEndpoint,
            peerId: PEER_ID? = nil,
            peerMetadata: PeerMetadata? = nil
        ) {
            self.connection = connection
            self.initiated = initiated
            self.peered = peered
            self.endpoint = endpoint
            self.peerId = peerId
            self.peerMetadata = peerMetadata
        }
    }

    public var peeredConnections: [PeerConnection] {
        connections.values.compactMap { holder in
            if let peerId = holder.peerId {
                PeerConnection(peerId: peerId, peerMetadata: holder.peerMetadata)
            } else {
                nil
            }
        }
    }

    var delegate: (any NetworkEventReceiver)?
    var peerId: PEER_ID? // this providers peer Id
    var peerMetadata: PeerMetadata? // this providers peer metadata

    var config: PeerToPeerProviderConfiguration

    // holds the tasks that manage receiving messages for initiated connections
    // (to external endpoints) - along with the retry logic to re-establish on
    // failure
    var ongoingReceiveMessageTasks: [Task<Void, any Error>]
    var connections: [NWEndpoint: ConnectionHolder]

    var browser: NWBrowser?
    var listener: NWListener?
    var txtRecord: NWTXTRecord

    // listener tasks to process/react to callbacks
    // from NWListener and NWNBrowser
    let stateStream: AsyncStream<NWListener.State>
    let stateContinuation: AsyncStream<NWListener.State>.Continuation
    var listenerStateUpdateTaskHandle: Task<Void, Never>?

    let newConnectionQueue: AsyncStream<NWConnection>
    let newConnectionContinuation: AsyncStream<NWConnection>.Continuation
    var newConnectionTaskHandle: Task<Void, Never>?

    // this allows us to create a provider, but it's not ready to go until
    // its fully configured by setting a delegate on it, which initializes
    // not only delegate, but also peerId and the optional peerMetadata
    // ``setDelegate``
    public init(_ config: PeerToPeerProviderConfiguration) {
        self.config = config
        connections = [:]
        delegate = nil
        peerId = nil
        peerMetadata = nil
        listener = nil
        browser = nil
        ongoingReceiveMessageTasks = []
        var record = NWTXTRecord()
        record[TXTRecordKeys.name] = config.peerName
        record[TXTRecordKeys.peer_id] = "UNCONFIGURED"
        self.txtRecord = record

        // AsyncStream as a queue to receive the updates
        (stateStream, stateContinuation) = AsyncStream<NWListener.State>.makeStream()
        // task handle to have some async process accepting and dealing with the results
        self.listenerStateUpdateTaskHandle = nil

        // The system calls this when a new connection arrives at the listener.
        // Start the connection to accept it, or cancel to reject it.
        (newConnectionQueue, newConnectionContinuation) = AsyncStream<NWConnection>.makeStream()
        self.newConnectionTaskHandle = nil
    }

    deinit {
        newConnectionTaskHandle?.cancel()
        listenerStateUpdateTaskHandle?.cancel()
        newConnectionTaskHandle = nil
        listenerStateUpdateTaskHandle = nil
    }

    // MARK: NetworkProvider Methods

    public func connect(to destination: NWEndpoint) async throws {
        if connections.values.contains(where: { ch in
            ch.endpoint == destination && ch.peered == true
        }) {
            throw Errors.NetworkProviderError(msg: "attempting to connect while already peered")
        }

        guard peerId != nil, delegate != nil else {
            throw Errors.NetworkProviderError(msg: "Attempting to connect before connected to a delegate")
        }

        if try await attemptConnect(to: destination) {
            let receiveAndRetry = Task.detached {
                try await self.ongoingReceivePeerMessages(endpoint: destination)
            }
            ongoingReceiveMessageTasks.append(receiveAndRetry)
        } else {
            throw Errors.NetworkProviderError(msg: "Unable to connect to \(destination.debugDescription)")
        }
    }

    public func disconnect() async {
        fatalError("Not Yet Implemented")
    }

    public func send(message _: SyncV1Msg, to _: PEER_ID?) async {
        fatalError("Not Yet Implemented")
    }

    public func setDelegate(
        _ delegate: any NetworkEventReceiver,
        as peerId: PEER_ID,
        with metadata: PeerMetadata?
    ) async {
        self.delegate = delegate
        self.peerId = peerId
        self.peerMetadata = metadata
    }

    // extra

    public func disconnect(_: PEER_ID) async {
        fatalError("Not Yet Implemented")
    }

    public func activate() {
        // if listener = true, set up a listener...
        fatalError("Not Yet Implemented")
    }

    // MARK: Outgoing connection functions

    // Returns a new websocketTask to track (at which point, save the url as the endpoint)
    // OR throws an error (log the error, but can retry)
    // OR returns nil if we don't have the pieces needed to reconnect (cease further attempts)
    private func attemptConnect(to destination: NWEndpoint?) async throws -> Bool {
        guard let destination,
              let peerId,
              let delegate
        else {
            return false
        }

        // establish the peer to peer connection
        let connection = await PeerToPeerConnection(to: destination, passcode: config.passcode)
        var holder = ConnectionHolder(connection: connection, initiated: true, peered: false, endpoint: destination)
        // indicate to everything else we're starting a connection, outgoing, not yet peered
        connections[destination] = holder

        Logger.peerProtocol.trace("Activating peer connection to \(destination.debugDescription, privacy: .public)")

        // since we initiated the WebSocket, it's on us to send an initial 'join'
        // protocol message to start the handshake phase of the protocol
        let joinMessage = SyncV1Msg.JoinMsg(senderId: peerId, metadata: peerMetadata)

        try await connection.send(.join(joinMessage))

        Logger.peerProtocol.trace("SEND: \(joinMessage.debugDescription)")

        do {
            // Race a timeout against receiving a Peer message from the other side
            // of the connection. If we fail that race, shut down the connection
            // and move into a .closed connectionState
            let nextMessage: SyncV1Msg = try await connection.receive(withTimeout: .seconds(3.5))

            // Now that we have the WebSocket message, figure out if we got what we expected.
            // For the sync protocol handshake phase, it's essentially "peer or die" since
            // we were the initiating side of the connection.

            guard case let .peer(peerMsg) = nextMessage else {
                throw SyncV1Msg.Errors.UnexpectedMsg(msg: nextMessage)
            }

            holder.peerId = peerMsg.senderId
            holder.peerMetadata = peerMsg.peerMetadata
            holder.peered = true
            let peerConnectionDetails = PeerConnection(peerId: peerMsg.senderId, peerMetadata: peerMsg.peerMetadata)
            await delegate.receiveEvent(event: .ready(payload: peerConnectionDetails))
            Logger.peerProtocol.trace("Peered to: \(peerMsg.senderId) \(peerMsg.debugDescription)")
            // update the reference to the connection with a peered version
            self.connections[destination] = holder

            return true
        } catch {
            // if there's an error, disconnect anything that's lingering and cancel it down.
            // an error here means we contacted the server successfully, but were unable to
            // peer, so we don't want to continue to attempt to reconnect. Because the "should
            // we reconnect" is a constant in the config, we can erase the URL endpoint instead
            // which will force us to fail reconnects.
            Logger.webSocket
                .error(
                    "Failed to peer with \(destination.debugDescription, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            await disconnect()
            throw error
        }
    }

    /// Infinitely loops over incoming messages from the websocket and updates the state machine based on the messages
    /// received.
    private func ongoingReceivePeerMessages(endpoint: NWEndpoint) async throws {
        // state needed for reconnect logic:
        // - should we reconnect on a receive() error/failure
        //   - let config.reconnectOnError: Bool
        // - where do we reconnect to?
        //   - var endpoint: URL?
        // - are we currently "peered" (authenticated), or does that need to be done before we
        //   cycle into listen and process mode?
        //   - var peered: Bool

        // local logic:
        // - how many times have we reconnected (to compute backoff/delay between
        //   reconnect attempts)
        var reconnectAttempts: UInt = 0

        while true {
            try Task.checkCancellation()

            guard let holder = connections[endpoint] else {
                break
            }

            // if we're not currently peered, attempt to reconnect
            // (if we're configured to do so)
            if !holder.peered, config.reconnectOnError {
                let waitBeforeReconnect = Backoff.delay(reconnectAttempts, withJitter: true)
                try await Task.sleep(for: .seconds(waitBeforeReconnect))
                // if endpoint is nil, this returns nil
                if try await attemptConnect(to: endpoint) {
                    reconnectAttempts += 1
                } else {
                    break
                }
            }

            guard var holder = connections[endpoint] else {
                break
            }

            try Task.checkCancellation()

            do {
                let msg = try await holder.connection.receive()
                await handleMessage(msg: msg)
            } catch {
                // error scenario with the WebSocket connection
                Logger.webSocket.warning("Error reading websocket: \(error.localizedDescription)")
                // update the stored copy of the holder with peered as false to indicate a
                // broken connection that can be re-attempted
                holder.peered = false
                connections[endpoint] = holder
            }
        }
        Logger.webSocket.log("receive and reconnect loop terminated")
    }

    private func handleMessage(msg: SyncV1Msg) async {
        // - .peer and .join messages should be handled here locally, and aren't expected
        //   in this method (all handling of them should happen before getting here)
        // - .leave invokes the disconnect, and associated messages to the delegate
        // - otherwise forward the message to the delegate to work with
        switch msg {
        case let .leave(msg):
            Logger.webSocket.trace("\(msg.senderId) requests to kill the connection")
            await disconnect()
        case let .join(msg):
            Logger.webSocket.error("Unexpected message received: \(msg.debugDescription)")
        case let .peer(msg):
            Logger.webSocket.error("Unexpected message received: \(msg.debugDescription)")
        default:
            await delegate?.receiveEvent(event: .message(payload: msg))
        }
    }

    // MARK: NWBrowser

    // MARK: NWListener handlers

    private func reactToNWListenerStateUpdate(_ newState: NWListener.State) async {
        guard let listener = self.listener else {
            return
        }
        switch newState {
        case .ready:
            if let port = listener.port {
                Logger.peerProtocol
                    .info("Bonjour listener ready on \(port.rawValue, privacy: .public)")
            } else {
                Logger.peerProtocol
                    .info("Bonjour listener ready (no port listed)")
            }
        case let .failed(error):
            if error == NWError.dns(DNSServiceErrorType(kDNSServiceErr_DefunctConnection)) {
                Logger.peerProtocol
                    .warning("Bonjour listener failed with \(error, privacy: .public), restarting.")
                listener.cancel()
                self.listener = nil
                self.setupBonjourListener()
            } else {
                Logger.peerProtocol
                    .error("Bonjour listener failed with \(error, privacy: .public), stopping.")
                listener.cancel()
            }
        case .setup:
            break
        case .waiting:
            break
        case .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func handleNewConnection(_ newConnection: NWConnection) async {
        Logger.peerProtocol
            .debug(
                "Receiving connection request from \(newConnection.endpoint.debugDescription, privacy: .public)"
            )
        Logger.peerProtocol
            .debug(
                "  Connection details: \(newConnection.debugDescription, privacy: .public)"
            )

        if connections[newConnection.endpoint] != nil {
            Logger.peerProtocol
                .info(
                    "Endpoint not yet recorded, accepting connection from \(newConnection.endpoint.debugDescription, privacy: .public)"
                )
            let peerConnection = await PeerToPeerConnection(
                connection: newConnection
            )
            let holder = ConnectionHolder(connection: peerConnection, initiated: false, peered: false, endpoint: newConnection.endpoint)
            connections[newConnection.endpoint] = holder
        } else {
            Logger.peerProtocol
                .info(
                    "Inbound connection already exists for \(newConnection.endpoint.debugDescription, privacy: .public), cancelling the connection request."
                )
            // If we already have a connection to that endpoint, don't add another
            newConnection.cancel()
        }
    }

    // Start listening and advertising.
    fileprivate func setupBonjourListener() {
        do {
            // Create the listener object.
            let listener = try NWListener(using: NWParameters.peerSyncParameters(passcode: config.passcode))
            // Set the service to advertise.
            listener.service = NWListener.Service(
                type: P2PAutomergeSyncProtocol.bonjourType,
                txtRecord: txtRecord
            )

            listenerStateUpdateTaskHandle = Task {
                for await newState in stateStream {
                    await reactToNWListenerStateUpdate(newState)
                }
            }

            newConnectionTaskHandle = Task {
                for await newConnection in newConnectionQueue {
                    await handleNewConnection(newConnection)
                }
            }

            // connect into the existing system by yielding the value
            // into the continuation that the stream provided on creation.
            listener.stateUpdateHandler = { newState in
                self.stateContinuation.yield(newState)
            }

            listener.newConnectionHandler = { newConnection in
                self.newConnectionContinuation.yield(newConnection)
            }

            // Start listening, and request updates on the main queue.
            listener.start(queue: .main)
            self.listener = listener
            Logger.peerProtocol
                .debug("Starting bonjour network listener")

        } catch {
            Logger.peerProtocol
                .critical("Failed to create bonjour listener")
        }
    }

    // Stop all listeners.
    fileprivate func stopListening() {
        listener?.cancel()
        listener = nil
    }

    // Update the advertised name on the network.
    fileprivate func resetName(_: String) {
//        for documentId in documents.keys {
//            if var txtRecord = txtRecords[documentId] {
//                txtRecord[TXTRecordKeys.name] = name
//                txtRecords[documentId] = txtRecord
//
//                // Reset the service to advertise.
//                listeners[documentId]?.service = NWListener.Service(
//                    type: P2PAutomergeSyncProtocol.bonjourType,
//                    txtRecord: txtRecord
//                )
//                Logger.syncController
//                    .debug(
//                        "Updated bonjour network listener to name \(name, privacy: .public) for document id
//                        \(documentId, privacy: .public)"
//                    )
//            } else {
//                Logger.syncController
//                    .error(
//                        "Unable to find TXTRecord for the registered Document: \(documentId, privacy: .public)"
//                    )
//            }
//        }
    }
}
