/*
 Copyright © 2022 Apple Inc.

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

 WWDC Video references aligned with this code:
 - https://developer.apple.com/videos/play/wwdc2019/713/
 - https://developer.apple.com/videos/play/wwdc2020/10110/
 */

import Automerge
@preconcurrency import Combine
import Foundation
import Network
import OSLog

/// A peer-to-peer connection to receive and send sync messages.
///
/// As soon as it is established, it attempts to commence a sync operation (send and expect to receive sync messages).
/// In addition, it includes an optional `trigger` in its initializer that, when it receives any signal value, kicks off
/// another attempt to sync the relevant Automerge document.
@AutomergeRepo
final class PeerToPeerConnection {
    // A Sendable wrapper around NWConnection to hold async handlers and relevant state
    // for the connection

    /// A published that provides updates of the connection's state.
    public nonisolated let connectionStatePublisher: PassthroughSubject<NWConnection.State, Never>
    /// The endpoint of the connection.
    public nonisolated let endpoint: NWEndpoint

    nonisolated let readyTimeout: ContinuousClock.Instant.Duration
    nonisolated let readyCheckDelay: ContinuousClock.Instant.Duration
    nonisolated let defaultReceiveTimeout: ContinuousClock.Instant.Duration
    nonisolated let initiated: Bool

    var peered: Bool // has the connection advanced to being peered and ready to go
    var peerId: PEER_ID? // if peered, should be non-nil
    var peerMetadata: PeerMetadata?

    let connectionQueue = DispatchQueue(label: "p2pconnection", qos: .default, attributes: .concurrent)
    nonisolated let connection: NWConnection

    struct ReceiveMessageData: Sendable {
        let content: Data?
        let contentContext: NWConnection.ContentContext?
        let isComplete: Bool
        let error: NWError?
    }

    /// Initiate a connection to a network endpoint to synchronize an Automerge Document.
    /// - Parameters:
    ///   - endpoint: The endpoint to attempt to connect.
    ///   - delegate: A delegate that can process Automerge sync protocol messages.
    ///   - trigger: A publisher that provides a recurring signal to trigger a sync request.
    ///   - docId: The document Id to use as a pre-shared key in TLS establishment of the connection.
    public init(
        to destination: NWEndpoint,
        passcode: String,
        receiveTimeout: ContinuousClock.Instant.Duration = .seconds(3.5),
        readyTimeout: ContinuousClock.Instant.Duration = .seconds(5),
        readyCheckDelay: ContinuousClock.Instant.Duration = .milliseconds(50)
    ) async {
        peered = false
        self.readyTimeout = readyTimeout
        self.defaultReceiveTimeout = receiveTimeout
        self.readyCheckDelay = readyCheckDelay
        self.initiated = true
        let connection = NWConnection(
            to: destination,
            using: NWParameters.peerSyncParameters(passcode: passcode)
        )
        endpoint = destination
        self.connectionStatePublisher = PassthroughSubject()
        self.connection = connection

        Logger.peerConnection
            .debug("Initiating connection to \(destination.debugDescription, privacy: .public)")
        Logger.peerConnection
            .debug(
                " - Initial state: \(String(describing: connection.state)) on path: \(String(describing: connection.currentPath))"
            )

        startConnection()
    }

    /// Accept an incoming connection.
    /// - Parameters:
    ///   - connection: The Network provided connection to wrap
    ///   - receiveTimeout: The timeout for expecting new messages
    ///   - readyTimeout: The timeout for waiting for the network connection to move into the ready state
    ///   - readyCheckDelay: The delay while checking the network connections state
    public init(
        connection: NWConnection,
        receiveTimeout: ContinuousClock.Instant.Duration = .seconds(3.5),
        readyTimeout: ContinuousClock.Instant.Duration = .seconds(5),
        readyCheckDelay: ContinuousClock.Instant.Duration = .milliseconds(50)
    ) {
        peered = false
        self.readyTimeout = readyTimeout
        self.defaultReceiveTimeout = receiveTimeout
        self.readyCheckDelay = readyCheckDelay
        self.initiated = false
        self.connection = connection
        endpoint = connection.endpoint
        connectionStatePublisher = PassthroughSubject()

        startConnection()
    }

    nonisolated func startConnection() {
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else {
                return
            }
            // warning here:
            // Non-sendable type 'PassthroughSubject<NWConnection.State, Never>' in asynchronous access to nonisolated
            // property 'connectionStatePublisher' cannot cross actor boundary
            // We're importing Combine with @preconcurrency to resolve the warning
            self.connectionStatePublisher.send(newState)
            let direction: String = self.initiated ? "to" : "from"
            switch newState {
            case .ready:
                Logger.peerConnection
                    .debug(
                        "NWConnection \(direction) \(self.connection.endpoint.debugDescription, privacy: .public) ready."
                    )
            // Ideally, we don't start attempting to receive connections until AFTER we're in a .ready state
            // START RECEIVING MESSAGES HERE
            case let .failed(error):
                Logger.peerConnection
                    .warning(
                        "FAILED: NWConnection \(direction) \(String(describing: self.connection), privacy: .public) : \(error, privacy: .public)"
                    )
                // Cancel the connection upon a failure.
                connection.cancel()

            case .cancelled:
                Logger.peerConnection
                    .debug(
                        "CANCELLED: NWConnection \(direction) \(self.connection.endpoint.debugDescription, privacy: .public) connection."
                    )

            case let .waiting(nWError):
                // from Network headers
                // `Waiting connections have not yet been started, or do not have a viable network`
                // So if we drop into this state, it's likely the network has shifted to non-viable
                // (for example, the wifi was disabled or dropped).
                //
                // Unclear if this is something we should retry ourselves when the associated network
                // path is again viable, or if this is something that the Network framework does on our
                // behalf.
                Logger.peerConnection
                    .warning(
                        "NWConnection \(direction) \(self.connection.endpoint.debugDescription, privacy: .public) waiting: \(nWError.debugDescription, privacy: .public)."
                    )

            case .preparing:
                Logger.peerConnection
                    .debug(
                        "NWConnection \(direction) \(self.connection.endpoint.debugDescription, privacy: .public) preparing."
                    )

            case .setup:
                Logger.peerConnection
                    .debug(
                        "NWConnection \(direction) \(self.connection.endpoint.debugDescription, privacy: .public) in setup."
                    )
            default:
                break
            }
        }

        // Start the connection establishment.
        connection.start(queue: connectionQueue)
    }

    /// Cancels the current connection.
    public nonisolated func cancel() {
        connection.cancel()
    }

    /// An error with the network connection.
    public struct NetworkConnectionError: Sendable, LocalizedError {
        public var msg: String
        public var err: NWError?
        public var errorDescription: String? {
            "NetworkConnectionError: \(msg)"
        }

        public init(msg: String, wrapping: NWError?) {
            self.msg = msg
            self.err = wrapping
        }
    }

    /// The network connection exceeded the timeout waiting to become ready.
    public struct ConnectionReadyTimeout: Sendable, LocalizedError {
        public let duration: ContinuousClock.Instant.Duration
        public var errorDescription: String? {
            "Connection didn't become ready in \(duration.description)"
        }

        public init(_ duration: ContinuousClock.Instant.Duration) {
            self.duration = duration
        }
    }

    /// The connection terminated.
    public struct ConnectionTerminated: Sendable, LocalizedError {
        public var errorDescription: String? {
            "Connection terminated."
        }

        public init() {}
    }

    // MARK: Automerge data to Automerge Sync Protocol transforms

    /// Sends an Automerge sync data packet.
    /// - Parameter syncMsg: The data to send.
    public func send(_ msg: SyncV1Msg) async throws {
        Logger.peerConnection.trace("CONN[\(String(describing: self.endpoint))] Sending: \(msg.debugDescription)")
        // Create a message object to hold the command type.
        let message = NWProtocolFramer.Message(syncMessageType: .syncV1data)
        let context = NWConnection.ContentContext(
            identifier: "Sync",
            metadata: [message]
        )

        let encodedMsg = try SyncV1Msg.encode(msg)
        // Send the app content along with the message.

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            connection.send(
                content: encodedMsg,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let nwerror: NWError = error {
                        continuation.resume(throwing: nwerror)
                    } else {
                        continuation.resume(returning: true)
                    }
                }
            )
        }
    }

    /// Receive a message.
    /// - Parameter withTimeout: The timeout to wait for the next message.
    /// - Returns: The Automerge sync message received, or an error indicating a network failure or timeout.
    ///
    /// This function throws an error on timeout exceeded, or if the task is cancelled.
    public nonisolated func receive(withTimeout: ContinuousClock.Instant.Duration?) async throws -> SyncV1Msg {
        let explicitTimeout: ContinuousClock.Instant.Duration = withTimeout ?? self.defaultReceiveTimeout
        // nil on timeout means we apply a default - 3.5 seconds, this setup keeps
        // the signature that _demands_ a timeout in the face of the developer (me)
        // who otherwise forgets its there.

        // Co-operatively check to see if we're cancelled, and if so - we can bail out before
        // going into the receive loop.
        try Task.checkCancellation()

        // Race a timeout against receiving a Peer message from the other side
        // of the WebSocket connection. If we fail that race, shut down the connection
        // and move into a .closed connectionState
        let msg = try await withThrowingTaskGroup(of: SyncV1Msg.self) { group in
            group.addTask {
                // retrieve the next websocket message
                try await self.receiveSingleMessage()
            }

            group.addTask {
                // Race against the receive call with a continuous timer
                try await Task.sleep(for: explicitTimeout)
                throw Errors.Timeout()
            }

            guard let msg = try await group.next() else {
                throw CancellationError()
            }
            // cancel all ongoing tasks (the websocket receive request, in this case)
            group.cancelAll()
            return msg
        }
        return msg
    }

    /// Receives and returns a single Automerge protocol sync message from the network connection.
    public func receiveSingleMessage() async throws -> SyncV1Msg {
        // schedules a single callback with the connection to provide the next, complete
        // message. That goes into an async stream (queue) help by this actor, and is
        // processed by an ongoing background task that calls `receiveMessageData`

        let rawMessageData = await withCheckedContinuation { continuation in
            // Hazard: Are you using the appropriate quality of service queue?
            connection.receiveMessage { content, context, isComplete, error in
                // packages up the callback details into a ReceiveMessageData struct
                // and yields it to the queue
                let data = ReceiveMessageData(
                    content: content,
                    contentContext: context,
                    isComplete: isComplete,
                    error: error
                )
                continuation.resume(returning: data)
            }
        }

        Logger.peerConnection
            .trace(
                "\(self.connection.debugDescription) Received a \(rawMessageData.isComplete ? "complete" : "incomplete", privacy: .public) msg on connection"
            )
        if let bytes = rawMessageData.content?.count {
            Logger.peerConnection.trace("\(self.connection.debugDescription)   - received \(bytes) bytes")
        } else {
            Logger.peerConnection.trace("\(self.connection.debugDescription)   - received no data with msg")
        }

        if let ctx = rawMessageData.contentContext, ctx.isFinal {
            Logger.peerConnection
                .warning("\(self.connection.debugDescription)   - received message is marked as final in TCP stream")
            self.cancel()
            throw ConnectionTerminated()
        }

        if let err = rawMessageData.error {
            Logger.peerConnection
                .error("\(self.connection.debugDescription)   - error on received message: \(err.localizedDescription)")
            // Kind of an open-question of if we should terminate the connection
            // on an error - I think so.
            self.cancel()
            // propagate the error back up to the caller
            throw err
        }

        // Extract your message type from the received context.
        guard let protocolMessage = rawMessageData.contentContext?
            .protocolMetadata(definition: P2PAutomergeSyncProtocol.definition) as? NWProtocolFramer.Message
        else {
            throw Errors.NetworkProviderError(msg: "Unable to read context of peer protocol message")
        }

        guard let data = rawMessageData.content else {
            throw Errors.NetworkProviderError(msg: "Received message without content")
        }

        switch protocolMessage.syncMessageType {
        case .unknown:
            Logger.peerConnection
                .warning(
                    "\(self.connection.debugDescription) received unknown msg \(data) from \(self.endpoint.debugDescription, privacy: .public)"
                )
            return SyncV1Msg.unknown(data)
        case .syncV1data:
            let msg = SyncV1Msg.decode(data)
            Logger.peerConnection.trace("\(self.connection.debugDescription) decoded to \(msg.debugDescription)")
            return msg
        }
    }
}
