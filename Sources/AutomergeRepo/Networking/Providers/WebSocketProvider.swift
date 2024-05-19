import Automerge
import Network
@preconcurrency import Combine
import OSLog

/// An Automerge-repo network provider that connects to other repositories using WebSocket.
@AutomergeRepo
public final class WebSocketProvider: NetworkProvider {
    /// The name of this provider.
    public let name = "WebSocket"

    /// A type that represents the configuration used to create the provider.
    public typealias ProviderConfiguration = WebSocketProviderConfiguration

    /// The active connection for this provider.
    public var peeredConnections: [PeerConnectionInfo]
    var delegate: (any NetworkEventReceiver)?
    var peerId: PEER_ID?
    var peerMetadata: PeerMetadata?
    var webSocketTask: URLSessionWebSocketTask?
    var ongoingReceiveMessageTask: Task<Void, any Error>?
    var config: WebSocketProviderConfiguration
    // reconnection logic variables
    var endpoint: URL?
    var peered: Bool

    private let _statePublisher: CurrentValueSubject<WebSocketProviderState, Never> =
        CurrentValueSubject(.disconnected)

    /// A publisher that provides state updates for the WebSocket connection.
    ///
    /// The initial value provides the current state of the connecting in the WebSocket provider,
    /// with updates published when the state changes.
    public nonisolated lazy var statePublisher: AnyPublisher<WebSocketProviderState, Never> = _statePublisher
        .removeDuplicates().eraseToAnyPublisher()

    /// Creates a new instance of a WebSocket network provider with the configuration you provide.
    /// - Parameter config: The configuration for the provider.
    public nonisolated init(_ config: WebSocketProviderConfiguration = .default) {
        self.config = config
        peeredConnections = []
        delegate = nil
        peerId = nil
        peerMetadata = nil
        webSocketTask = nil
        ongoingReceiveMessageTask = nil
        peered = false
    }
    
    /// Initiate an outgoing connection.
    public func connect(to url: URL) async throws {
        if peered {
            Logger.websocket.error("Attempting to connect while already peered")
            throw Errors.NetworkProviderError(msg: "Attempting to connect while already peered")
        }

        guard peerId != nil, delegate != nil else {
            Logger.websocket.error("Attempting to connect before connected to a delegate")
            throw Errors.NetworkProviderError(msg: "Attempting to connect before connected to a delegate")
        }

        if try await attemptConnect(to: url) {
            if config.logLevel.canTrace() {
                Logger.websocket.trace("WEBSOCKET: connected to \(url)")
            }
            endpoint = url
        } else {
            if config.logLevel.canTrace() {
                Logger.websocket.trace("WEBSOCKET: failed to connect to \(url)")
            }
            return
        }

        assert(peered == true)

        // If we have an existing task there, looping over messages, it means there was
        // one previously set up, and there was a connection failure - at which point
        // a reconnect was created to re-establish the webSocketTask.
        if ongoingReceiveMessageTask == nil {
            // infinitely loop and receive messages, but "out of band"
            ongoingReceiveMessageTask = Task.detached {
                await self.ongoingReceiveWebSocketMessages()
                if await self.config.logLevel.canTrace() {
                    Logger.websocket.trace("Terminated background read loop - socket expected to be disconnected")
                }
            }
        }
    }

    /// Disconnect and terminate any existing connection.
    public func disconnect() async {
        peered = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        ongoingReceiveMessageTask?.cancel()
        ongoingReceiveMessageTask = nil
        endpoint = nil
        _statePublisher.send(.disconnected)

        if let connectedPeer = peeredConnections.first {
            peeredConnections.removeAll()
            await delegate?.receiveEvent(event: .peerDisconnect(payload: .init(peerId: connectedPeer.peerId)))
        }

        await delegate?.receiveEvent(event: .close)
    }

    /// Requests the network transport to send a message.
    /// - Parameter message: The message to send.
    /// - Parameter to: An option peerId to identify the recipient for the message. If nil, the message is sent to all
    /// connected peers.
    public func send(message: SyncV1Msg, to: PEER_ID?) async {
        guard let webSocketTask else {
            Logger.websocket.warning("WEBSOCKET: Attempt to send a message without a connection")
            if config.logLevel.canTrace() {
                Logger.websocket.trace("WEBSOCKET: - msg \(message.debugDescription) to peer \(String(describing: to))")
            }
            return
        }
        var msgToSend = message
        if let peer = peerId {
            msgToSend = message.setTarget(to ?? peer)
        } else {
            Logger.websocket.warning("WEBSOCKET: No peer set to revise targeting of broadcast events")
        }
        do {
            if config.logLevel.canTrace() {
                Logger.websocket.trace("WEBSOCKET: SEND \(msgToSend.debugDescription)")
            }
            let data = try SyncV1Msg.encode(msgToSend)
            try await webSocketTask.send(.data(data))
        } catch {
            Logger.websocket
                .error("WEBSOCKET: Unable to encode and send message: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Set the delegate for the peer to peer provider.
    /// - Parameters:
    ///   - delegate: The delegate instance.
    ///   - peerId: The peer ID to use for the peer to peer provider.
    ///   - metadata: The peer metadata, if any, to use for the peer to peer provider.
    ///
    /// This is typically called when the delegate adds the provider, and provides this network
    /// provider with a peer ID and associated metadata, as well as an endpoint that receives
    /// Automerge sync protocol sync message and network events.
    public func setDelegate(
        _ delegate: any NetworkEventReceiver,
        as peer: PEER_ID,
        with metadata: PeerMetadata?
    ) {
        self.delegate = delegate
        peerId = peer
        peerMetadata = metadata
    }

    // MARK: utility methods

    private func attemptToDecode(_ msg: URLSessionWebSocketTask.Message, peerOnly: Bool = false) throws -> SyncV1Msg {
        // Now that we have the WebSocket message, figure out if we got what we expected.
        // For the sync protocol handshake phase, it's essentially "peer or die" since
        // we were the initiating side of the connection.
        switch msg {
        case let .data(raw_data):
            if peerOnly {
                let msg = SyncV1Msg.decodePeer(raw_data)
                if case .peer = msg {
                    return msg
                } else {
                    // In the handshake phase and received anything other than a valid peer message
                    let decodeAttempted = SyncV1Msg.decode(raw_data)
                    Logger.websocket
                        .warning(
                            "WEBSOCKET: Decoding message, expecting peer only - and it wasn't a peer message. RECEIVED MSG: \(String(describing: decodeAttempted))"
                        )
                    throw Errors.UnexpectedMsg(msg: String(describing: decodeAttempted))
                }
            } else {
                let decodedMsg = SyncV1Msg.decode(raw_data)
                if case .unknown = decodedMsg {
                    Logger.websocket.warning("Unexpected message: \(decodedMsg.debugDescription)")
                    throw Errors.UnexpectedMsg(msg: decodedMsg.debugDescription)
                }
                return decodedMsg
            }

        case let .string(string):
            // In the handshake phase and received anything other than a valid peer message
            Logger.websocket
                .warning("WEBSOCKET: Unknown message received: .string(\(string))")
            throw Errors.UnexpectedMsg(msg: string)
        @unknown default:
            // In the handshake phase and received anything other than a valid peer message
            Logger.websocket
                .error("WEBSOCKET: Unknown message received: \(String(describing: msg))")
            throw Errors.UnexpectedMsg(msg: String(describing: msg))
        }
    }

    // Returns a `true` on success OR throws an error (log the error, but can retry)
    func attemptConnect(to url: URL?) async throws -> Bool {
        precondition(peered == false)
        guard let url,
              let peerId,
              let delegate
        else {
            if config.logLevel.canTrace() {
                Logger.websocket.trace("Pre-requisites not available for attemptConnect, returning nil")
                Logger.websocket.trace("URL: \(String(describing: url))")
                Logger.websocket.trace("PeerID: \(String(describing: self.peerId))")
                Logger.websocket.trace("Delegate: \(String(describing: self.delegate))")
            }
            return false
        }

        // establish the WebSocket connection

        let request = URLRequest(url: url)
        let webSocketTask = URLSession.shared.webSocketTask(with: request)
        if config.logLevel.canTrace() {
            Logger.websocket.trace("WEBSOCKET: Activating websocket to \(url, privacy: .public)")
        }
        // start the websocket processing things
        webSocketTask.resume()

        // since we initiated the WebSocket, it's on us to send an initial 'join'
        // protocol message to start the handshake phase of the protocol
        let joinMessage = SyncV1Msg.JoinMsg(senderId: peerId, metadata: peerMetadata)
        let data = try SyncV1Msg.encode(joinMessage)
        try await webSocketTask.send(.data(data))
        _statePublisher.send(.connected)
        do {
            // Race a timeout against receiving a Peer message from the other side
            // of the WebSocket connection. If we fail that race, shut down the connection
            // and move into a .closed connectionState
            let websocketMsg = try await nextMessage(on: webSocketTask, withTimeout: .seconds(3.5))

            // Now that we have the WebSocket message, figure out if we got what we expected.
            // For the sync protocol handshake phase, it's essentially "peer or die" since
            // we were the initiating side of the connection.
            guard case let .peer(peerMsg) = try attemptToDecode(websocketMsg, peerOnly: true) else {
                Logger.websocket.warning("Unexpected message: \(String(describing: websocketMsg))")
                throw Errors.UnexpectedMsg(msg: String(describing: websocketMsg))
            }
            if config.logLevel.canTrace() {
                Logger.websocket.trace("WEBSOCKET: RECV: \(peerMsg.debugDescription)")
            }
            peered = true
            let peerConnectionDetails = PeerConnectionInfo(
                peerId: peerMsg.senderId,
                peerMetadata: peerMsg.peerMetadata,
                endpoint: url.absoluteString,
                initiated: true,
                peered: peered
            )
            peeredConnections = [peerConnectionDetails]
            // these need to be set _before_ we send the delegate message that we're
            // peered, because that process in turn (can trigger/triggers) a sync
            endpoint = url
            self.webSocketTask = webSocketTask

            await delegate.receiveEvent(event: .ready(payload: peerConnectionDetails))
            _statePublisher.send(.ready)
            if config.logLevel.canTrace() {
                Logger.websocket.trace("WEBSOCKET: Peered to targetId: \(peerMsg.senderId) \(peerMsg.debugDescription)")
            }
        } catch {
            // if there's an error, cancel anything lingering to shut down the websocket,
            // and set all the pieces to nil. Reconnection is decided outside this function, so
            // we don't want to erase the endpoint or call self.disconnect() to tear everything down.
            Logger.websocket
                .error(
                    "WEBSOCKET: Failed to peer with \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            webSocketTask.cancel()
            self.webSocketTask = nil
            peered = false
            _statePublisher.send(.disconnected)
            throw error
        }

        return true
    }

    // throw error on timeout
    // throw error on cancel
    // otherwise return the msg
    private nonisolated func nextMessage(
        on webSocketTask: URLSessionWebSocketTask,
        withTimeout: ContinuousClock.Instant
            .Duration?
    ) async throws -> URLSessionWebSocketTask.Message {
        // nil on timeout means we apply a default - 3.5 seconds, this setup keeps
        // the signature that _demands_ a timeout in the face of the developer (me)
        // who otherwise forgets its there.
        let timeout: ContinuousClock.Instant.Duration = if let providedTimeout = withTimeout {
            providedTimeout
        } else {
            .seconds(3.5)
        }

        // Co-operatively check to see if we're cancelled, and if so - we can bail out before
        // going into the receive loop.
        try Task.checkCancellation()

        // Race a timeout against receiving a Peer message from the other side
        // of the WebSocket connection. If we fail that race, shut down the connection
        // and move into a .closed connectionState
        let websocketMsg = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                // retrieve the next websocket message
                try await webSocketTask.receive()
            }

            group.addTask {
                // Race against the receive call with a continuous timer
                try await Task.sleep(for: timeout)
                if await self.config.logLevel.canTrace() {
                    Logger.websocket.trace("WEBSOCKET: TIMEOUT \(timeout) waiting for next messsage")
                }
                throw Errors.Timeout()
            }

            guard let msg = try await group.next() else {
                if await self.config.logLevel.canTrace() {
                    Logger.websocket.trace("WEBSOCKET: throwing CancellationError")
                }
                throw CancellationError()
            }
            // cancel all ongoing tasks (the websocket receive request, in this case)
            group.cancelAll()
            return msg
        }
        return websocketMsg
    }

    /// Loops over incoming messages from the websocket and updates the state machine based on the messages
    /// received.
    ///
    /// If the provider configuration (``WebSocketProviderConfiguration``) has `reconnectOnError`
    /// set to `true`, this function attempts to re-establish a WebSocket connection on connection
    /// failure or read error. If that value is false, the connection terminates on error and the provider
    /// reports the connection as ``WebSocketProviderState/disconnected``.
    ///
    /// If `reconnectOnError`, and `maxNumberOfConnectRetries` has a positive value, a maximum number of retries
    /// is enforced. After the provided maximum number of retries, the connection is fully reset and left in the
    /// state ``WebSocketProviderState/disconnected``.
    private func ongoingReceiveWebSocketMessages() async {
        // state needed for reconnect logic:
        // - should we reconnect on a receive() error/failure
        //   - let config.reconnectOnError: Bool
        // - where do we reconnect to?
        //   - var endpoint: URL?
        // - are we currently "peered" (authenticated), or does that need to be done before we
        //   cycle into listen and process mode?
        //   - var peered: Bool

        var msgFromWebSocket: URLSessionWebSocketTask.Message?
        // local logic:
        // - how many times have we reconnected (to compute backoff/delay between
        //   reconnect attempts)
        var reconnectAttempts: UInt = 0
        var tryToReconnect = config.reconnectOnError
        
        repeat {
            msgFromWebSocket = nil

            // co-operative cancellation
            if Task.isCancelled {
                webSocketTask?.cancel()
                webSocketTask = nil
                peered = false
                tryToReconnect = false
                break
            }
            

            // if we're not currently peered, attempt to reconnect
            // (if we're configured to do so)
            if !peered, tryToReconnect {
                if let maxRetries = config.maxNumberOfConnectRetries, maxRetries > 0, maxRetries > reconnectAttempts {
                    // maxNumber of connection retries is set, positive, and exceeds the
                    // number of attempts already made...
                    tryToReconnect = false
                    break
                }

                _statePublisher.send(.reconnecting)
                let waitBeforeReconnect = Backoff.delay(reconnectAttempts, withJitter: true)
                if config.logLevel.canTrace() {
                    Logger.websocket
                        .trace(
                            "WEBSOCKET: Reconnect attempt #\(reconnectAttempts), waiting for \(waitBeforeReconnect) seconds."
                        )
                }
                reconnectAttempts += 1
                                
                do {
                    // Wait to reconnect. Wait for waitBeforeReconnect and networth path
                    // transitioning from not satisfied to satisfied. Whichever comes first.
                    let success = try await withThrowingTaskGroup(of: Void.self) { group in

                        // Wait for timeout
                        group.addTask {
                            try await Task.sleep(for: .seconds(waitBeforeReconnect))
                        }
                        
                        // Wait for network becomming availible
                        group.addTask {
                            let monitor = NWPathMonitor()
                            var last = monitor.currentPath
                            for await each in monitor.paths() {
                                if last.status != .satisfied && each.status == .satisfied {
                                    Logger.websocket.info("WEBSOCKET: Network path satisfied while waiting to reconnect")
                                    return
                                } else {
                                    last = each
                                }
                            }
                        }
                        
                        // This is what I want, but warns of data races
                        // _ = try await group.next()
                        // group.cancelAll()
                        // return true
                        
                        // This accomplishes same thing as previous comment, but doesn't warn of data races
                        for try await _ in group {
                            let success = try await attemptConnect(to: endpoint)
                            group.cancelAll()
                            return success
                        }
                        
                        return false
                    }
                    
                    if success {
                        // On successful connection reset connection attemtps
                        reconnectAttempts = 0
                    }
                } catch {
                    webSocketTask = nil
                    peered = false
                }
            }

            // co-operative cancellation
            if Task.isCancelled {
                tryToReconnect = false
                break
            }

            do {
                msgFromWebSocket = try await webSocketTask?.receive()
            } catch {
                // error scenario with the WebSocket connection
                Logger.websocket.warning("WEBSOCKET: Error reading websocket: \(error.localizedDescription)")
                _statePublisher.send(.disconnected)
                peered = false
                msgFromWebSocket = nil
            }

            if let encodedMessage = msgFromWebSocket {
                do {
                    let msg = try attemptToDecode(encodedMessage)
                    if config.logLevel.canTrace() {
                        Logger.websocket.trace("WEBSOCKET: RECV: \(msg.debugDescription)")
                    }
                    await handleMessage(msg: msg)
                } catch {
                    // catch decode failures, but don't terminate the whole shebang
                    // on a failure
                    Logger.websocket
                        .warning(
                            "WEBSOCKET: Unable to decode websocket message: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
        } while tryToReconnect
        
        self.peered = false
        webSocketTask?.cancel()
        webSocketTask = nil
        _statePublisher.send(.disconnected)
        Logger.websocket.warning("WEBSOCKET: receive and reconnect loop terminated")
    }

    func handleMessage(msg: SyncV1Msg) async {
        // - .peer and .join messages should be handled here locally, and aren't expected
        //   in this method (all handling of them should happen before getting here)
        // - .leave invokes the disconnect, and associated messages to the delegate
        // - otherwise forward the message to the delegate to work with
        switch msg {
        case let .leave(msg):
            if config.logLevel.canTrace() {
                Logger.websocket.trace("WEBSOCKET: \(msg.senderId) requests to kill the connection")
            }
            await disconnect()
        case let .join(msg):
            Logger.websocket.error("WEBSOCKET: Unexpected message received: \(msg.debugDescription)")
        case let .peer(msg):
            Logger.websocket.error("WEBSOCKET: Unexpected message received: \(msg.debugDescription)")
        default:
            await delegate?.receiveEvent(event: .message(payload: msg))
            if config.logLevel.canTrace() {
                Logger.websocket.trace("WEBSOCKET: FWD TO DELEGATE: \(msg.debugDescription)")
            }
        }
    }
}
