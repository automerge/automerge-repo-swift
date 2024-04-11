import AsyncAlgorithms
import Foundation
import Network
import OSLog

public actor PeerToPeerProvider: NetworkProvider {
    public typealias NetworkConnectionEndpoint = NWEndpoint

    /// A wrapper around PeerToPeer connection that holds additional metadata about the connection
    /// relevant for the PeerToPeer provider, exposing a copy of its endpoint and latest updated Peering
    /// state so that it can be used from synchronous calls inside this actor.
    struct ConnectionHolder: Sendable {
        var connection: PeerToPeerConnection
        var initiated: Bool // is this an outgoing/initiated connection
        var endpoint: NWEndpoint
        var peered: Bool // has the connection advanced to being peered and ready to go
        var peerId: PEER_ID? // if peered, should be non-nil
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

    public struct AvailablePeer: Sendable {
        let peerId: PEER_ID
        let endpoint: NWEndpoint
        let name: String
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
    let supportedProtocolVersion = "1"

    // holds the tasks that manage receiving messages for initiated connections
    // (to external endpoints) - along with the retry logic to re-establish on
    // failure
    var ongoingReceiveMessageTasks: [NWEndpoint: Task<Void, any Error>]
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

    // browser tasks to process/react to callbacks
    let browserStateStream: AsyncStream<NWBrowser.State>
    let browserStateContinuation: AsyncStream<NWBrowser.State>.Continuation
    var browserStateUpdateTaskHandle: Task<Void, Never>?

    struct BrowserResultUpdate: Sendable {
        let newResults: Set<NWBrowser.Result>
        let changes: Set<NWBrowser.Result.Change>
    }

    let browserResultUpdateStream: AsyncStream<BrowserResultUpdate>
    let browserResultUpdateContinuation: AsyncStream<BrowserResultUpdate>.Continuation
    var browserResultUpdateTaskHandle: Task<Void, Never>?

    public let availablePeerChannel: AsyncChannel<[AvailablePeer]>

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
        ongoingReceiveMessageTasks = [:]
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

        (browserStateStream, browserStateContinuation) = AsyncStream<NWBrowser.State>.makeStream()
        self.browserStateUpdateTaskHandle = nil

        (browserResultUpdateStream, browserResultUpdateContinuation) = AsyncStream<BrowserResultUpdate>.makeStream()
        self.browserStateUpdateTaskHandle = nil

        self.availablePeerChannel = AsyncChannel()
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
            ongoingReceiveMessageTasks[destination] = receiveAndRetry
        } else {
            throw Errors.NetworkProviderError(msg: "Unable to connect to \(destination.debugDescription)")
        }
    }

    public func disconnect() async {
        for receivingTasks in ongoingReceiveMessageTasks {
            receivingTasks.value.cancel()
        }

        for holder in connections.values {
            await holder.connection.cancel()
        }
        connections.removeAll()
    }

    public func send(message: SyncV1Msg, to peer: PEER_ID?) async {
        if let peerId = peer {
            let holdersWithPeer: [ConnectionHolder] = connections.values.filter { h in
                h.peerId == peerId
            }
            for holder in holdersWithPeer {
                do {
                    try await holder.connection.send(message)
                } catch {
                    Logger.peerProtocol
                        .warning(
                            "error encoding message \(message.debugDescription, privacy: .public). Unable to send to peer \(peerId)"
                        )
                }
            }
        } else {
            // nil peerId means send to everyone...
            for holder in connections.values {
                // only send to connections with a set PeerId
                if let peerId = holder.peerId {
                    do {
                        try await holder.connection.send(message)
                    } catch {
                        Logger.peerProtocol
                            .warning(
                                "error encoding message \(message.debugDescription, privacy: .public). Unable to send to endpoint \(peerId)"
                            )
                    }
                }
            }
        }
    }

    public func setDelegate(
        _ delegate: any NetworkEventReceiver,
        as peerId: PEER_ID,
        with metadata: PeerMetadata?
    ) async {
        self.delegate = delegate
        self.peerId = peerId
        self.peerMetadata = metadata

        // if listener = true, set up a listener...
        if config.listening {
            if listener == nil {
                self.setupBonjourListener()
            }
        }
    }

    // MARK: Extra provider methods for listener & multi-connection

    /// Cancels and removes the connection for a given peerId
    /// - Parameter peerId: the peer Id to disconnect from either receiving or initiated connection
    public func disconnect(peerId: PEER_ID) async {
        let holdersWithPeer: [ConnectionHolder] = connections.values.filter { h in
            h.peerId == peerId
        }
        for holder in holdersWithPeer {
            // terminate the receive/message processing concurrent task
            if let receivingTask = ongoingReceiveMessageTasks[holder.endpoint] {
                receivingTask.cancel()
            }
            // cancel the connection itself
            await holder.connection.cancel()
            // remove the connection from our collection
            connections.removeValue(forKey: holder.endpoint)
        }
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
                throw SyncV1Msg.Errors.UnexpectedMsg(msg: nextMessage.debugDescription)
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

    /// Infinitely loops over incoming messages from the peer connection and updates the state machine based on the
    /// messages
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

    // Start browsing for services.
    fileprivate func startBrowsing() {
        // Create parameters, and allow browsing over a peer-to-peer link.
        let browserNetworkParameters = NWParameters()
        browserNetworkParameters.includePeerToPeer = true

        // Browse for the Automerge sync bonjour service type.
        let newNetworkBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(type: P2PAutomergeSyncProtocol.bonjourType, domain: nil),
            using: browserNetworkParameters
        )

        browserStateUpdateTaskHandle = Task {
            for await newState in browserStateStream {
                await reactToNWBrowserStateUpdate(newState)
            }
        }

        // connect into the existing system by yielding the value
        // into the continuation that the stream provided on creation.
        newNetworkBrowser.stateUpdateHandler = { newState in
            self.browserStateContinuation.yield(newState)
        }

        browserResultUpdateTaskHandle = Task {
            for await update in browserResultUpdateStream {
                await handleNWBrowserUpdates(update)
            }
        }

        newNetworkBrowser.browseResultsChangedHandler = { results, changes in
            self.browserResultUpdateContinuation.yield(BrowserResultUpdate(newResults: results, changes: changes))
        }

        Logger.peerProtocol.info("Activating NWBrowser \(newNetworkBrowser.debugDescription, privacy: .public)")
        browser = newNetworkBrowser
        // Start browsing and ask for updates on the main queue.
        newNetworkBrowser.start(queue: .main)
    }

    private func reactToNWBrowserStateUpdate(_ newState: NWBrowser.State) async {
        switch newState {
        case let .failed(error):
            // Restart the browser if it loses its connection.
            if error == NWError.dns(DNSServiceErrorType(kDNSServiceErr_DefunctConnection)) {
                Logger.peerProtocol.info("Browser failed with \(error, privacy: .public), restarting")
                self.browser?.cancel()
                self.startBrowsing()
            } else {
                Logger.peerProtocol.warning("Browser failed with \(error, privacy: .public), stopping")
                self.browser?.cancel()
            }
        case .ready:
            break
        case .cancelled:
            break
        default:
            break
        }
    }

    private func handleNWBrowserUpdates(_ update: BrowserResultUpdate) async {
        Logger.peerProtocol.debug("browser update shows \(update.newResults.count, privacy: .public) result(s):")

        let availablePeers = update.newResults.compactMap { browserResult in
            Logger.peerProtocol
                .debug(
                    "  \(browserResult.endpoint.debugDescription, privacy: .public) \(browserResult.metadata.debugDescription, privacy: .public)"
                )
            if case let .bonjour(txtRecord) = browserResult.metadata,
               let name = txtRecord[TXTRecordKeys.name],
               let peerId = txtRecord[TXTRecordKeys.name]
            {
                return AvailablePeer(peerId: peerId, endpoint: browserResult.endpoint, name: name)
            }
            return nil
        }
        await availablePeerChannel.send(availablePeers)

        if config.autoconnect {
            for change in update.changes {
                if case let .added(result) = change {
                    do {
                        try await connect(to: result.endpoint)
                    } catch {
                        Logger.peerProtocol
                            .warning(
                                "Attempted to connect to \(result.endpoint.debugDescription), but failed: \(error.localizedDescription)"
                            )
                    }
                }
            }
        }
    }

    fileprivate func stopBrowsing() {
        guard let browser else { return }
        Logger.peerProtocol.info("Terminating NWBrowser")
        browser.cancel()
        self.browser = nil
    }

    // MARK: NWListener handlers

    private func reactToNWListenerStateUpdate(_ newState: NWListener.State) async {
        // nothing external here, but there could be - this is primarily for logging
        // status while debugging at the moment, and to provide the capability to
        // recreate the listener in case it fails
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

    private func handleNewConnection(_ newConnection: NWConnection) async {
        guard let delegate = self.delegate else {
            // if there's no delegate, we're unconfigured and not yet ready
            // to handle any new connections
            return
        }
        Logger.peerProtocol
            .debug(
                "Receiving connection request from \(newConnection.endpoint.debugDescription, privacy: .public)"
            )
        Logger.peerProtocol
            .debug(
                "  Connection details: \(newConnection.debugDescription, privacy: .public)"
            )

        let peerConnection = await PeerToPeerConnection(
            connection: newConnection
        )

        // check to see if there's already a connection with this endpoint, if there is
        // on recorded (even if it's not yet peered), don't accept the incoming connection.
        if connections[newConnection.endpoint] != nil {
            Logger.peerProtocol
                .info(
                    "Endpoint not yet recorded, accepting connection from \(newConnection.endpoint.debugDescription, privacy: .public)"
                )
            let holder = ConnectionHolder(
                connection: peerConnection,
                initiated: false,
                peered: false,
                endpoint: newConnection.endpoint
            )
            connections[newConnection.endpoint] = holder

            do {
                if let peerConnectionDetails = try await attemptToPeer(holder) {
                    let receiveAndRetry = Task.detached {
                        try await self.ongoingListenerReceivePeerMessages(endpoint: holder.endpoint)
                    }
                    ongoingReceiveMessageTasks[holder.endpoint] = receiveAndRetry

                    await delegate.receiveEvent(event: .ready(payload: peerConnectionDetails))
                }
            } catch {
                // error thrown during peering
                await holder.connection.cancel()
                connections.removeValue(forKey: holder.endpoint)
            }
            // SET UP THE ATTEMPT TO PEER AND RECURRING READ HERE
        } else {
            Logger.peerProtocol
                .info(
                    "Inbound connection already exists for \(newConnection.endpoint.debugDescription, privacy: .public), cancelling the connection request."
                )
            // If we already have a connection to that endpoint, don't add another
            newConnection.cancel()
        }
    }

    // MARK: Incoming connection functions

    // Returns a new websocketTask to track (at which point, save the url as the endpoint)
    // OR throws an error (terminate on error - no retry)
    // OR returns nil if we don't have the pieces needed to reconnect (cease further attempts)
    private func attemptToPeer(_ holder: ConnectionHolder) async throws -> PeerConnection? {
        // can't/shouldn't peer if we're not yet fully configured
        guard let peerId,
              let delegate
        else {
            return nil
        }

        var holderCopy = holder
        // Race a timeout against receiving a Join message from the other side
        // of the connection. If we fail that race, shut down the connection
        // and move into a .closed connectionState
        let nextMessage: SyncV1Msg = try await holderCopy.connection.receive(withTimeout: .seconds(3.5))

        // Now that we have the WebSocket message, figure out if we got what we expected.
        // For the sync protocol handshake phase, it's essentially "peer or die" since
        // we were the initiating side of the connection.

        guard case let .join(joinMsg) = nextMessage else {
            throw SyncV1Msg.Errors.UnexpectedMsg(msg: nextMessage.debugDescription)
        }

        // send the peer candidate information
        let peerConnectionDetails = PeerConnection(peerId: joinMsg.senderId, peerMetadata: joinMsg.peerMetadata)
        await delegate.receiveEvent(event: .peerCandidate(payload: peerConnectionDetails))

        // check to verify the requested protocol version matches what we're expecting
        if joinMsg.supportedProtocolVersions != supportedProtocolVersion {
            throw Errors.UnsupportedProtocolError(msg: joinMsg.supportedProtocolVersions)
        }

        // update the reference to the connection with a peered version
        holderCopy.peerId = joinMsg.senderId
        holderCopy.peerMetadata = joinMsg.peerMetadata
        holderCopy.peered = true
        connections[holderCopy.endpoint] = holderCopy

        Logger.peerProtocol
            .trace("Accepting peer connection from \(holder.endpoint.debugDescription, privacy: .public)")

        // reply with the corresponding "peer" message
        let peerMessage = SyncV1Msg.PeerMsg(
            senderId: peerId,
            targetId: joinMsg.senderId,
            storageId: self.peerMetadata?.storageId,
            ephemeral: self.peerMetadata?.isEphemeral ?? true
        )

        try await holderCopy.connection.send(.peer(peerMessage))
        Logger.peerProtocol.trace("SEND: \(peerMessage.debugDescription)")
        return peerConnectionDetails
    }

    /// Infinitely loops over incoming messages from the peer connection and updates the state machine based on the
    /// messages
    /// received.
    private func ongoingListenerReceivePeerMessages(endpoint: NWEndpoint) async throws {
        while true {
            try Task.checkCancellation()

            guard let holder = connections[endpoint],
                  let peerId = holder.peerId,
                  holder.peered == true
            else {
                break
            }

            do {
                let msg = try await holder.connection.receive()
                await handleMessage(msg: msg)
            } catch {
                // error scenario with the PeerToPeer connection
                Logger.peerProtocol.warning("Error reading connection: \(error.localizedDescription)")
                await disconnect(peerId: peerId)
                break
            }
        }
        Logger.peerProtocol.warning("receive and reconnect loop for \(endpoint.debugDescription) terminated")
    }

    // Stop all listeners.
    fileprivate func stopListening() {
        listener?.cancel()
        listener = nil
    }

    // Update the advertised name on the network.
    fileprivate func resetName(_ name: String) {
        txtRecord[TXTRecordKeys.name] = name

        // Reset the service to advertise.
        listener?.service = NWListener.Service(
            type: P2PAutomergeSyncProtocol.bonjourType,
            txtRecord: txtRecord
        )
        Logger.peerProtocol.info("Updated bonjour network listener to advertise name \(name, privacy: .public)")
    }
}
