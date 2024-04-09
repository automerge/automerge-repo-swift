import OSLog

public actor WebSocketProvider: NetworkProvider {
    public typealias ProviderConfiguration = WebSocketProviderConfiguration
    public struct WebSocketProviderConfiguration: Sendable {
        let reconnectOnError: Bool

        public static let `default` = WebSocketProviderConfiguration(reconnectOnError: true)
    }

    public var peeredConnections: [PeerConnection]
    var delegate: (any NetworkEventReceiver)?
    var peerId: PEER_ID?
    var peerMetadata: PeerMetadata?
    var webSocketTask: URLSessionWebSocketTask?
    var ongoingReceiveMessageTask: Task<Void, any Error>?
    var config: WebSocketProviderConfiguration
    // reconnection logic variables
    var endpoint: URL?
    var peered: Bool

    public init(_ config: WebSocketProviderConfiguration = .default) {
        self.config = config
        peeredConnections = []
        delegate = nil
        peerId = nil
        peerMetadata = nil
        webSocketTask = nil
        ongoingReceiveMessageTask = nil
        peered = false
    }

    // MARK: NetworkProvider Methods

    public func connect(to url: URL) async throws {
        if peered {
            throw Errors.NetworkProviderError(msg: "attempting to connect while already peered")
        }

        guard peerId != nil, delegate != nil else {
            throw Errors.NetworkProviderError(msg: "Attempting to connect before connected to a delegate")
        }

        if let websocket = try await attemptConnect(to: url) {
            endpoint = url
            webSocketTask = websocket
        }

        assert(peered == true)

        // If we have an existing task there, looping over messages, it means there was
        // one previously set up, and there was a connection failure - at which point
        // a reconnect was created to re-establish the webSocketTask.
        if ongoingReceiveMessageTask == nil {
            // infinitely loop and receive messages, but "out of band"
            ongoingReceiveMessageTask = Task.detached {
                try await self.ongoingReceiveWebSocketMessages()
            }
        }
    }

    public func disconnect() async {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        ongoingReceiveMessageTask?.cancel()
        ongoingReceiveMessageTask = nil
        endpoint = nil

        if let connectedPeer = peeredConnections.first {
            peeredConnections.removeAll()
            await delegate?.receiveEvent(event: .peerDisconnect(payload: .init(peerId: connectedPeer.peerId)))
        }

        await delegate?.receiveEvent(event: .close)
    }

    public func send(message: SyncV1Msg, to _: PEER_ID?) async {
        guard let webSocketTask else {
            Logger.webSocket.warning("Attempt to send a message without a connection")
            return
        }

        do {
            let data = try SyncV1Msg.encode(message)
            try await webSocketTask.send(.data(data))
        } catch {
            Logger.webSocket.error("Unable to encode and send message: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func setDelegate(
        _ delegate: any NetworkEventReceiver,
        as peer: PEER_ID,
        with metadata: PeerMetadata?
    ) async {
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
                    Logger.webSocket
                        .warning(
                            "Decoding websocket message, expecting peer only - and it wasn't a peer message. RECEIVED MSG: \(decodeAttempted.debugDescription)"
                        )
                    throw SyncV1Msg.Errors.UnexpectedMsg(msg: decodeAttempted)
                }
            } else {
                let decodedMsg = SyncV1Msg.decode(raw_data)
                if case .unknown = decodedMsg {
                    throw SyncV1Msg.Errors.UnexpectedMsg(msg: decodedMsg)
                }
                return decodedMsg
            }

        case let .string(string):
            // In the handshake phase and received anything other than a valid peer message
            Logger.webSocket
                .warning("Unknown websocket message received: .string(\(string))")
            throw SyncV1Msg.Errors.UnexpectedMsg(msg: msg)
        @unknown default:
            // In the handshake phase and received anything other than a valid peer message
            Logger.webSocket
                .error("Unknown websocket message received: \(String(describing: msg))")
            throw SyncV1Msg.Errors.UnexpectedMsg(msg: msg)
        }
    }

    // Returns a new websocketTask to track (at which point, save the url as the endpoint)
    // OR throws an error (log the error, but can retry)
    // OR returns nil if we don't have the pieces needed to reconnect (cease further attempts)
    func attemptConnect(to url: URL?) async throws -> URLSessionWebSocketTask? {
        precondition(peered == false)
        guard let url,
              let peerId,
              let delegate
        else {
            return nil
        }

        // establish the WebSocket connection

        let request = URLRequest(url: url)
        let webSocketTask = URLSession.shared.webSocketTask(with: request)
        Logger.webSocket.trace("Activating websocket to \(url, privacy: .public)")
        // start the websocket processing things
        webSocketTask.resume()

        // since we initiated the WebSocket, it's on us to send an initial 'join'
        // protocol message to start the handshake phase of the protocol
        let joinMessage = SyncV1Msg.JoinMsg(senderId: peerId, metadata: peerMetadata)
        let data = try SyncV1Msg.encode(joinMessage)
        try await webSocketTask.send(.data(data))
        Logger.webSocket.trace("SEND: \(joinMessage.debugDescription)")

        do {
            // Race a timeout against receiving a Peer message from the other side
            // of the WebSocket connection. If we fail that race, shut down the connection
            // and move into a .closed connectionState
            let websocketMsg = try await nextMessage(withTimeout: .seconds(3.5))

            // Now that we have the WebSocket message, figure out if we got what we expected.
            // For the sync protocol handshake phase, it's essentially "peer or die" since
            // we were the initiating side of the connection.
            guard case let .peer(peerMsg) = try attemptToDecode(websocketMsg, peerOnly: true) else {
                throw SyncV1Msg.Errors.UnexpectedMsg(msg: websocketMsg)
            }

            let newPeerConnection = PeerConnection(peerId: peerMsg.senderId, peerMetadata: peerMsg.peerMetadata)
            peeredConnections = [newPeerConnection]
            peered = true
            await delegate.receiveEvent(event: .ready(payload: newPeerConnection))
            Logger.webSocket.trace("Peered to targetId: \(peerMsg.senderId) \(peerMsg.debugDescription)")
        } catch {
            // if there's an error, disconnect anything that's lingering and cancel it down.
            // an error here means we contacted the server successfully, but were unable to
            // peer, so we don't want to continue to attempt to reconnect. Because the "should
            // we reconnect" is a constant in the config, we can erase the URL endpoint instead
            // which will force us to fail reconnects.
            Logger.webSocket
                .error(
                    "Failed to peer with \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            await disconnect()
            throw error
        }

        return webSocketTask
    }

    // throw error on timeout
    // throw error on cancel
    // otherwise return the msg
    private func nextMessage(
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

        // check the invariants
        guard let webSocketTask
        else {
            throw SyncV1Msg.Errors
                .ConnectionClosed(errorDescription: "Attempting to wait for a websocket message when the task is nil")
        }

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
                throw SyncV1Msg.Errors.Timeout()
            }

            guard let msg = try await group.next() else {
                throw CancellationError()
            }
            // cancel all ongoing tasks (the websocket receive request, in this case)
            group.cancelAll()
            return msg
        }
        return websocketMsg
    }

    /// Infinitely loops over incoming messages from the websocket and updates the state machine based on the messages
    /// received.
    private func ongoingReceiveWebSocketMessages() async throws {
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

        while true {
            msgFromWebSocket = nil
            try Task.checkCancellation()

            // if we're not currently peered, attempt to reconnect
            // (if we're configured to do so)
            if !peered, config.reconnectOnError {
                let waitBeforeReconnect = Backoff.delay(reconnectAttempts, withJitter: true)
                try await Task.sleep(for: .seconds(waitBeforeReconnect))
                // if endpoint is nil, this returns nil
                if let newWebSocketTask = try await attemptConnect(to: endpoint) {
                    reconnectAttempts += 1
                    webSocketTask = newWebSocketTask
                    peered = true
                } else {
                    webSocketTask = nil
                    peered = false
                }
            }

            guard let webSocketTask else {
                Logger.webSocket.warning("Receive Handler: webSocketTask is nil, terminating handler loop")
                break // terminates the while loop - no more reconnect attempts
            }

            try Task.checkCancellation()

            do {
                msgFromWebSocket = try await webSocketTask.receive()
            } catch {
                // error scenario with the WebSocket connection
                Logger.webSocket.warning("Error reading websocket: \(error.localizedDescription)")
            }

            if let encodedMessage = msgFromWebSocket {
                do {
                    let msg = try attemptToDecode(encodedMessage)
                    await handleMessage(msg: msg)
                } catch {
                    // catch decode failures, but don't terminate the whole shebang
                    // on a failure
                    Logger.webSocket
                        .warning("Unable to decode websocket message: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        Logger.webSocket.log("receive and reconnect loop terminated")
    }

    func handleMessage(msg: SyncV1Msg) async {
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
}
