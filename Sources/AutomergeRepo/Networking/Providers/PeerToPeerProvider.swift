import AsyncAlgorithms
import Combine
import Foundation
import Network
import OSLog

/// A Peer to Peer Network provider
///
/// Provides a incoming and outgoing connections to peers available over Bonjour.
@AutomergeRepo
public final class PeerToPeerProvider: NetworkProvider {
    public typealias NetworkConnectionEndpoint = NWEndpoint

    private func allConnections() -> [PeerConnectionInfo] {
        connections.values.compactMap { holder in
            if let peerId = holder.peerId {
                PeerConnectionInfo(
                    peerId: peerId,
                    peerMetadata: holder.peerMetadata,
                    endpoint: holder.endpoint.debugDescription,
                    initiated: holder.initiated,
                    peered: holder.peered
                )
            } else {
                nil
            }
        }
    }

    /// The list of active connections that have been authorized
    public var peeredConnections: [PeerConnectionInfo] {
        allConnections().filter { conn in
            conn.peered == true
        }
    }

    var delegate: (any NetworkEventReceiver)?
    var peerId: PEER_ID? // this providers peer Id
    var peerMetadata: PeerMetadata? // this providers peer metadata

    /// The name that this provider broadcasts as the human-readable identity.
    public var peerName: String

    // the human-readable name to advertise on Bonjour alongside peerId

    var config: PeerToPeerProviderConfiguration
    let supportedProtocolVersion = "1"

    // holds the tasks that manage receiving messages for initiated connections
    // (to external endpoints) - along with the retry logic to re-establish on
    // failure
    var ongoingReceiveMessageTasks: [NWEndpoint: Task<Void, any Error>]
    var connections: [NWEndpoint: PeerToPeerConnection]
    var availablePeers: [AvailablePeer]

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

    // public let availablePeerChannel: AsyncChannel<[AvailablePeer]>
    // Combine alternate for availablePeerChannel - accessible to SwiftUI Views
    /// A publisher that provides updates of available peers seen by the provider when active.
    public nonisolated let availablePeerPublisher: PassthroughSubject<[AvailablePeer], Never> = PassthroughSubject()
    /// A publisher that provides updates of connections with this provider when active.
    public nonisolated let connectionPublisher: PassthroughSubject<[PeerConnectionInfo], Never> = PassthroughSubject()
    /// A publisher that provides updates of the Bonjour browser state, when active.
    public nonisolated let browserStatePublisher: PassthroughSubject<NWBrowser.State, Never> = PassthroughSubject()
    /// A publisher that provides updates of the Bonjour listener state, when active.
    public nonisolated let listenerStatePublisher: PassthroughSubject<NWListener.State, Never> = PassthroughSubject()

    /// Creates a new Peer to Peer network provider
    /// - Parameter config: The configuration for the provider.
    ///
    /// Creating a provider by itself is insufficient to use it. Set the providers
    /// delegate using ``setDelegate(_:as:with:)`` to fully initialize it before use.
    /// Setting initializes a peerId and its peer metadata from the delegate.
    public nonisolated init(_ config: PeerToPeerProviderConfiguration) {
        self.config = config
        connections = [:]
        availablePeers = []
        delegate = nil
        peerId = nil
        peerMetadata = nil
        listener = nil
        browser = nil
        peerName = ""
        ongoingReceiveMessageTasks = [:]
        var record = NWTXTRecord()
        record[TXTRecordKeys.name] = peerName
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
    }

    deinit {
        newConnectionTaskHandle?.cancel()
        listenerStateUpdateTaskHandle?.cancel()
        newConnectionTaskHandle = nil
        listenerStateUpdateTaskHandle = nil
    }

    // MARK: NetworkProvider Methods

    /// Initiate a connection to a Bonjour endpoint
    /// - Parameter destination: The endpoint to connect
    public func connect(to destination: NWEndpoint) async throws {
        do {
            if connections.values.contains(where: { ch in
                ch.endpoint == destination && ch.peered == true
            }) {
                throw Errors.NetworkProviderError(msg: "Attempting to connect while already peered")
            }

            guard peerId != nil, delegate != nil else {
                throw Errors.NetworkProviderError(msg: "Attempting to connect before connected to a delegate")
            }

            if try await attemptConnect(to: destination) {
                Logger.peerProtocol.trace("Connection established to \(destination.debugDescription)")
                let receiveAndRetry = Task.detached {
                    try await self.ongoingReceivePeerMessages(endpoint: destination)
                }
                ongoingReceiveMessageTasks[destination] = receiveAndRetry
            } else {
                throw Errors.NetworkProviderError(msg: "Unable to connect to \(destination.debugDescription)")
            }
        } catch {
            Logger.peerProtocol.error("Failed to connect: \(error.localizedDescription)")
            throw error
        }
    }

    /// Disconnect all existing connections.
    public func disconnect() {
        for receivingTasks in ongoingReceiveMessageTasks {
            receivingTasks.value.cancel()
        }

        for holder in connections.values {
            holder.connection.cancel()
        }
        Logger.peerProtocol.debug("Terminating \(self.connections.count) connections")
        connections.removeAll()
        // could be connectionPublisher.send(allConnections()), but we just removed them all...
        connectionPublisher.send([])
    }

    /// Send an Automerge sync protocol message.
    /// - Parameters:
    ///   - message: The message to send
    ///   - peer: An optional peer to send it to. If nil, send will broadcast the message to all connected peers.
    public func send(message: SyncV1Msg, to peer: PEER_ID?) async {
        if let peerId = peer {
            let holdersWithPeer: [PeerToPeerConnection] = connections.values.filter { h in
                h.peerId == peerId
            }
            for holder in holdersWithPeer {
                do {
                    try await holder.send(message)
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
                        try await holder.send(message)
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

    /// Set the delegate for the peer to peer provider.
    ///
    /// This is typically called when the delegate adds the provider, and provides this network
    /// provider with a peer ID and associated metadata, as well as an endpoint that receives
    /// Automerge sync protocol sync message and network events.
    /// - Parameters:
    ///   - delegate: The delegate instance.
    ///   - peerId: The peer ID to use for the peer to peer provider.
    ///   - metadata: The peer metadata to use for the peer to peer provider.
    public func setDelegate(
        _ delegate: any NetworkEventReceiver,
        as peerId: PEER_ID,
        with metadata: PeerMetadata?
    ) {
        self.delegate = delegate
        self.peerId = peerId
        txtRecord[TXTRecordKeys.peer_id] = peerId
        self.peerMetadata = metadata
    }

    // MARK: Extra provider methods for listener & multi-connection

    /// Cancels and removes the connection for a given peer
    /// - Parameter peerId: the peer Id to disconnect from either receiving or initiated connection
    public func disconnect(peerId: PEER_ID) {
        let holdersWithPeer: [PeerToPeerConnection] = connections.values.filter { h in
            h.peerId == peerId
        }
        for holder in holdersWithPeer {
            // terminate the receive/message processing concurrent task
            if let receivingTask = ongoingReceiveMessageTasks[holder.endpoint] {
                receivingTask.cancel()
            }
            // cancel the connection itself
            holder.connection.cancel()
            // remove the connection from our collection
            connections.removeValue(forKey: holder.endpoint)
            connectionPublisher.send(allConnections())
        }
    }

    /// Starts the Peer to Peer networking provider.
    ///
    /// This initiates a listener to accept connections, and a browser to watch for available
    /// endpoints.
    /// - Parameter peerName: An optional human-readable name to be used when broadcasting this provider as an available
    /// peer.
    public func startListening(as peerName: String? = nil) async throws {
        if let peerName {
            setName(peerName)
        }
        if self.peerName.isEmpty {
            throw Errors.NetworkProviderError(msg: "No peer name is set on the provider")
        }

        Logger.peerProtocol.debug("Starting Bonjour browser")
        if browser == nil {
            self.startBrowsing()
        }

        Logger.peerProtocol.debug("Starting Bonjour listener as \(self.peerName)")
        Logger.peerProtocol.debug(" - PeerId: \(self.peerId ?? "unset")")
        Logger.peerProtocol.debug(" - PeerMetadata: \(self.peerMetadata?.debugDescription ?? "nil")")
        Logger.peerProtocol.debug(" - Autoconnect on appearing host: \(self.config.autoconnect)")
        Logger.peerProtocol.debug(" - Delegate: \(String(describing: self.delegate))")
        if listener == nil {
            self.setupBonjourListener()
        }
    }

    /// Terminate the Peer to Peer network provider.
    ///
    /// This terminates all connections, incoming and outgoing, and disables future connections.
    public func stopListening() {
        Logger.peerProtocol.debug("Stopping Bonjour browser")
        self.stopBrowsing()
        browser = nil

        Logger.peerProtocol.debug("Stopping Bonjour listener")
        disconnect()
        listener?.cancel()
        listener = nil
        availablePeerPublisher.send([])
        browserStatePublisher.send(.setup)
        listenerStatePublisher.send(.setup)
    }

    // MARK: Outgoing connection functions

    // Returns a boolean indicating we were able to connect to the destination
    // OR throws an error (log the error, but can retry)
    private func attemptConnect(to destination: NWEndpoint?) async throws -> Bool {
        guard let destination,
              let peerId,
              let delegate
        else {
            return false
        }

        // establish the peer to peer connection
        let peerConnection = await PeerToPeerConnection(to: destination, passcode: config.passcode)
        // indicate to everything else we're starting a connection, outgoing, not yet peered

        // report that this connection exists to all interested
        connections[destination] = peerConnection
        connectionPublisher.send(allConnections())

        do {
            // start process to "peer" with endpoint
            Logger.peerProtocol
                .trace(
                    "Connection established, requesting peering with \(destination.debugDescription, privacy: .public)"
                )
            // since we initiated the connection, it's on us to send an initial 'join'
            // protocol message to start the handshake phase of the protocol
            let joinMessage = SyncV1Msg.JoinMsg(senderId: peerId, metadata: peerMetadata)
            try await peerConnection.send(.join(joinMessage))
            Logger.peerProtocol.trace("SENT: \(joinMessage.debugDescription)")

            // Race a timeout against receiving a Peer message from the other side
            // of the connection. If we fail that race, shut down the connection
            // and move into a .closed connectionState
            let nextMessage: SyncV1Msg = try await peerConnection.receive(withTimeout: config.waitForPeerTimeout)

            // Now that we have a message, figure out if we got what we expected.
            // For the sync protocol handshake phase, it's essentially "peer or die" since
            // we were the initiating side of the connection.

            guard case let .peer(peerMsg) = nextMessage else {
                throw SyncV1Msg.Errors.UnexpectedMsg(msg: nextMessage.debugDescription)
            }

            peerConnection.peerId = peerMsg.senderId
            peerConnection.peerMetadata = peerMsg.peerMetadata
            peerConnection.peered = true
            let peerConnectionDetails = PeerConnectionInfo(
                peerId: peerId,
                peerMetadata: peerConnection.peerMetadata,
                endpoint: peerConnection.endpoint.debugDescription,
                initiated: peerConnection.initiated,
                peered: peerConnection.peered
            )
            await delegate.receiveEvent(event: .ready(payload: peerConnectionDetails))
            Logger.peerProtocol.trace("Peered to: \(peerMsg.senderId) \(peerMsg.debugDescription)")

            connectionPublisher.send(allConnections())
            return true
        } catch {
            // if there's an error, disconnect anything that's lingering and cancel it down.
            // an error here means we contacted the server successfully, but were unable to
            // peer, so we don't want to continue to attempt to reconnect. Because the "should
            // we reconnect" is a constant in the config, we can erase the URL endpoint instead
            // which will force us to fail reconnects.
            self.connections.removeValue(forKey: destination)
            connectionPublisher.send(allConnections())
            Logger.peerProtocol
                .error(
                    "Failed to peer with \(destination.debugDescription, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
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

            guard let holder = connections[endpoint] else {
                break
            }

            try Task.checkCancellation()

            do {
                let msg = try await holder.receive(withTimeout: config.recurringNextMessageTimeout)
                await handleMessage(msg: msg)
            } catch {
                // error scenario with the connection
                Logger.peerProtocol.warning("Error reading from connection: \(error.localizedDescription)")
                // update the stored copy of the holder with peered as false to indicate a
                // broken connection that can be re-attempted
                holder.peered = false
                connections[endpoint] = holder
                connectionPublisher.send(allConnections())
            }
        }
        Logger.peerProtocol.log("receive and reconnect loop terminated")
    }

    private func handleMessage(msg: SyncV1Msg) async {
        // - .peer and .join messages should be handled here locally, and aren't expected
        //   in this method (all handling of them should happen before getting here)
        // - .leave invokes the disconnect, and associated messages to the delegate
        // - otherwise forward the message to the delegate to work with
        switch msg {
        case let .leave(msg):
            Logger.peerProtocol.trace("\(msg.senderId) requests to kill the connection")
            disconnect(peerId: msg.senderId)
        case let .join(msg):
            Logger.peerProtocol.error("Unexpected message received: \(msg.debugDescription)")
        case let .peer(msg):
            Logger.peerProtocol.error("Unexpected message received: \(msg.debugDescription)")
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
        Logger.peerProtocol.trace("\(self.peerName) NWBrowser state -> \(String(describing: newState))")
        browserStatePublisher.send(newState)
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
        Logger.peerProtocol
            .debug("\(self.peerName) NWBrowser update with \(update.newResults.count, privacy: .public) result(s):")

        let availablePeers = update.newResults.compactMap { browserResult in
            Logger.peerProtocol
                .debug(
                    "  \(browserResult.endpoint.debugDescription, privacy: .public) \(browserResult.metadata.debugDescription, privacy: .public)"
                )
            if case let .bonjour(txtRecord) = browserResult.metadata,
               let name = txtRecord[TXTRecordKeys.name],
               let peerId = txtRecord[TXTRecordKeys.peer_id]
            {
                return AvailablePeer(peerId: peerId, endpoint: browserResult.endpoint, name: name)
            }
            return nil
        }
        self.availablePeers = availablePeers
        availablePeerPublisher.send(availablePeers)

        if config.autoconnect {
            for change in update.changes {
                if case let .added(result) = change {
                    do {
                        Logger.peerProtocol.debug("AutoConnect attempting to: \(result.endpoint.debugDescription)")
                        switch result.metadata {
                        case .none:
                            Logger.peerProtocol.debug("  - No metadata available")
                        case let .bonjour(txtRecord):
                            Logger.peerProtocol.debug("  - \(txtRecord.debugDescription)")
                        @unknown default:
                            fatalError("Unknown metadata on Bonjour browser result")
                        }
                        Logger.peerProtocol.debug("AutoConnect attempting to: \(result.interfaces)")
                        try await connect(to: result.endpoint)
                    } catch {
                        Logger.peerProtocol
                            .warning(
                                "Failed to connect to \(result.endpoint.debugDescription): \(error.localizedDescription)"
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
        listenerStatePublisher.send(newState)
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

        Logger.peerProtocol.debug("Existing connections:")
        Logger.peerProtocol.debug("----------------------------------------------------------")
        for (k, v) in connections {
            let peeredString = v.peered ? "true" : "false"
            let initiatedString = v.initiated ? "true" : "false"
            let peerString = v.peerId ?? "nil"

            Logger.peerProtocol.debug("\(k.debugDescription)")
            Logger.peerProtocol.debug(" :: peerId: \(peerString)")
            Logger.peerProtocol.debug(" :: initiated: \(initiatedString)")
            Logger.peerProtocol.debug(" :: peered: \(peeredString)")
            Logger.peerProtocol.debug("----------------------------------------------------------")
        }

        // check to see if there's already a connection with this endpoint, if there is
        // on recorded (even if it's not yet peered), don't accept the incoming connection.
        if connections[newConnection.endpoint] == nil {
            Logger.peerProtocol
                .info(
                    "Endpoint not yet recorded, accepting connection from \(newConnection.endpoint.debugDescription, privacy: .public)"
                )
            let peerConnection = PeerToPeerConnection(connection: newConnection)
//            let holder = ConnectionHolder(
//                connection: peerConnection,
//                initiated: false,
//                peered: false,
//                endpoint: newConnection.endpoint
//            )
            connections[newConnection.endpoint] = peerConnection
            connectionPublisher.send(allConnections())

            do {
                if let peerConnectionDetails = try await attemptToPeer(peerConnection) {
                    let receiveAndRetry = Task.detached {
                        try await self.ongoingListenerReceivePeerMessages(endpoint: peerConnection.endpoint)
                    }
                    ongoingReceiveMessageTasks[peerConnection.endpoint] = receiveAndRetry

                    await delegate.receiveEvent(event: .ready(payload: peerConnectionDetails))
                }
            } catch {
                // error thrown during peering
                peerConnection.connection.cancel()
                connections.removeValue(forKey: peerConnection.endpoint)
                connectionPublisher.send(allConnections())
            }
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

    // Returns a new PeerConnection to track (at which point, save the url as the endpoint)
    // OR throws an error (terminate on error - no retry)
    // OR returns nil if we don't have the pieces needed to reconnect (cease further attempts)
    private func attemptToPeer(_ holder: PeerToPeerConnection) async throws -> PeerConnectionInfo? {
        // can't/shouldn't peer if we're not yet fully configured
        guard let peerId,
              let delegate
        else {
            return nil
        }

//        var holderCopy = holder
        // Race a timeout against receiving a Join message from the other side
        // of the connection. If we fail that race, shut down the connection
        // and move into a .closed connectionState
        let nextMessage: SyncV1Msg = try await holder.receive(withTimeout: config.waitForPeerTimeout)

        // Now that we have a message, figure out if we got what we expected.
        // For the sync protocol handshake phase, it's essentially "peer or die" since
        // we were the initiating side of the connection.

        guard case let .join(joinMsg) = nextMessage else {
            throw SyncV1Msg.Errors.UnexpectedMsg(msg: nextMessage.debugDescription)
        }

        // send the peer candidate information
        let peerConnectionDetails = PeerConnectionInfo(
            peerId: joinMsg.senderId,
            peerMetadata: joinMsg.peerMetadata,
            endpoint: holder.endpoint.debugDescription,
            initiated: holder.initiated,
            peered: holder.peered
        )
        await delegate.receiveEvent(event: .peerCandidate(payload: peerConnectionDetails))

        // check to verify the requested protocol version matches what we're expecting
        if joinMsg.supportedProtocolVersions != supportedProtocolVersion {
            throw Errors.UnsupportedProtocolError(msg: joinMsg.supportedProtocolVersions)
        }

        // update the reference to the connection with a peered version
        holder.peerId = joinMsg.senderId
        holder.peerMetadata = joinMsg.peerMetadata
        holder.peered = true
//        connections[holderCopy.endpoint] = holderCopy
        connectionPublisher.send(allConnections())

        Logger.peerProtocol
            .trace("Accepting peer connection from \(holder.endpoint.debugDescription, privacy: .public)")

        // reply with the corresponding "peer" message
        let peerMessage = SyncV1Msg.PeerMsg(
            senderId: peerId,
            targetId: joinMsg.senderId,
            storageId: self.peerMetadata?.storageId,
            ephemeral: self.peerMetadata?.isEphemeral ?? true
        )

        try await holder.send(.peer(peerMessage))
        Logger.peerProtocol.trace("SEND: \(peerMessage.debugDescription)")
        return peerConnectionDetails
    }

    /// Infinitely loops over incoming messages from the peer connection and updates the state machine based on the
    /// messages received.
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
                let msg = try await holder.receive(withTimeout: config.recurringNextMessageTimeout)
                await handleMessage(msg: msg)
            } catch {
                // error scenario with the PeerToPeer connection
                Logger.peerProtocol.warning("Error reading connection: \(error.localizedDescription)")
                disconnect(peerId: peerId)
                break
            }
        }
        Logger.peerProtocol.warning("receive and reconnect loop for \(endpoint.debugDescription) terminated")
    }

    // Update the advertised name on the network.
    public func setName(_ name: String) {
        if name == "Sparrow" {
            print("X")
        }
        self.peerName = name
        txtRecord[TXTRecordKeys.name] = name

        // Reset the service to advertise.
        listener?.service = NWListener.Service(
            type: P2PAutomergeSyncProtocol.bonjourType,
            txtRecord: txtRecord
        )
        Logger.peerProtocol.info("Updated bonjour network listener to advertise name \(name, privacy: .public)")
    }
}
