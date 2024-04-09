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
import Foundation
import Network
import OSLog

/// A peer to peer sync connection to receive and send sync messages.
///
/// As soon as it is established, it attempts to commence a sync operation (send and expect to receive sync messages).
/// In addition, it includes an optional `trigger` in its initializer that, when it receives any signal value, kicks off
/// another attempt to sync the relevant Automerge document.
public actor PeerToPeerConnection {
    struct ReceiveMessageData: Sendable {
        let content: Data?
        let contentContext: NWConnection.ContentContext?
        let isComplete: Bool
        let error: NWError?
    }

    // A Sendable wrapper around NWConnection to hold async handlers and relevant state
    // for the connection

    var connection: NWConnection
    /// A Boolean value that indicates this app initiated this connection.

    var endpoint: NWEndpoint?

    let stateStream: AsyncStream<NWConnection.State>
    let stateContinuation: AsyncStream<NWConnection.State>.Continuation
    var listenerStateUpdateTaskHandle: Task<Void, Never>?

    let messageDataStream: AsyncStream<ReceiveMessageData>
    let receiveMessageContinuation: AsyncStream<ReceiveMessageData>.Continuation

    /// Initiate a connection to a network endpoint to synchronise an Automerge Document.
    /// - Parameters:
    ///   - endpoint: The endpoint to attempt to connect.
    ///   - delegate: A delegate that can process Automerge sync protocol messages.
    ///   - trigger: A publisher that provides a recurring signal to trigger a sync request.
    ///   - docId: The document Id to use as a pre-shared key in TLS establishment of the connection.
    init(to
        destination: NWEndpoint,
        passcode: String
    ) async {
        let connection = NWConnection(
            to: destination,
            using: NWParameters.peerSyncParameters(passcode: passcode)
        )
        self.connection = connection
        self.endpoint = destination
        Logger.peerConnection
            .debug("Initiating connection to \(destination.debugDescription, privacy: .public)")
        // AsyncStream as a queue to receive the updates
        let (stream, continuation) = AsyncStream<NWConnection.State>.makeStream()
        // task handle to have some async process accepting and dealing with the results
        listenerStateUpdateTaskHandle = nil

        self.stateStream = stream
        self.stateContinuation = continuation
        // connect into the existing system by yielding the value
        // into the continuation that the stream provided on creation.

        (messageDataStream, receiveMessageContinuation) = AsyncStream<ReceiveMessageData>.makeStream()

        connection.stateUpdateHandler = { newState in
            self.stateContinuation.yield(newState)
        }

        listenerStateUpdateTaskHandle = Task {
            for await newState in stateStream {
                await handleConnectionStateUpdate(newState)
            }
        }

        // Start the connection establishment.
        connection.start(queue: .main)
    }

    init(connection: NWConnection) async {
        self.connection = connection
        endpoint = connection.endpoint

        // AsyncStream as a queue to receive the updates
        let (stream, continuation) = AsyncStream<NWConnection.State>.makeStream()
        // task handle to have some async process accepting and dealing with the results
        listenerStateUpdateTaskHandle = nil

        self.stateStream = stream
        self.stateContinuation = continuation
        // connect into the existing system by yielding the value
        // into the continuation that the stream provided on creation.

        (messageDataStream, receiveMessageContinuation) = AsyncStream<ReceiveMessageData>.makeStream()

        // connect into the existing system by yielding the value
        // into the continuation that the stream provided on creation.
        connection.stateUpdateHandler = { newState in
            self.stateContinuation.yield(newState)
        }

        // Start the connection establishment.
        connection.start(queue: .main)
    }

    /// Cancels the current connection.
    public func cancel() {
        connection.cancel()
    }

    func handleConnectionStateUpdate(_ newState: NWConnection.State) async {
        switch newState {
        case .ready:
            Logger.peerConnection
                .debug(
                    "connection to \(self.connection.endpoint.debugDescription, privacy: .public) ready."
                )
        case let .failed(error):
            Logger.peerConnection
                .warning(
                    "FAILED \(String(describing: self.connection), privacy: .public) : \(error, privacy: .public)"
                )
            // Cancel the connection upon a failure.
            connection.cancel()

        case .cancelled:
            Logger.peerConnection
                .debug(
                    "CANCEL \(self.endpoint.debugDescription, privacy: .public) connection."
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
                    "connection to \(self.connection.endpoint.debugDescription, privacy: .public) waiting: \(nWError.debugDescription, privacy: .public)."
                )

        case .preparing:
            Logger.peerConnection
                .debug(
                    "connection to \(self.connection.endpoint.debugDescription, privacy: .public) preparing."
                )

        case .setup:
            Logger.peerConnection
                .debug(
                    "connection to \(self.connection.endpoint.debugDescription, privacy: .public) in setup."
                )
        default:
            break
        }
    }

    // MARK: Automerge data to Automerge Sync Protocol transforms

    /// Sends an Automerge sync data packet.
    /// - Parameter syncMsg: The data to send.
    public func send(_ msg: SyncV1Msg) throws {
        // Create a message object to hold the command type.
        let message = NWProtocolFramer.Message(syncMessageType: .syncV1data)
        let context = NWConnection.ContentContext(
            identifier: "Sync",
            metadata: [message]
        )

        let encodedMsg = try SyncV1Msg.encode(msg)
        // Send the app content along with the message.
        connection.send(
            content: encodedMsg,
            contentContext: context,
            isComplete: true,
            completion: .idempotent
        )
    }

    
    // throw error on timeout
    // throw error on cancel
    // otherwise return the msg
    public func receive(withTimeout: ContinuousClock.Instant.Duration?) async throws -> SyncV1Msg {
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
        let msg = try await withThrowingTaskGroup(of: SyncV1Msg.self) { group in
            group.addTask {
                // retrieve the next websocket message
                try await self.receive()
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
        return msg
    }

    public func receive() async throws -> SyncV1Msg {
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
            .debug(
                "Received a \(rawMessageData.isComplete ? "complete" : "incomplete", privacy: .public) msg on connection"
            )
        if let bytes = rawMessageData.content?.count {
            Logger.peerConnection.trace("  - received \(bytes) bytes")
        } else {
            Logger.peerConnection.trace("  - received no data with msg")
        }

        if let err = rawMessageData.error {
            Logger.peerConnection.error("  - error on received message: \(err.localizedDescription)")
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

        guard let currentEndpoint = endpoint else {
            throw Errors.NetworkProviderError(msg: "Received message with endpoint unset")
        }

        guard let data = rawMessageData.content else {
            throw Errors.NetworkProviderError(msg: "Received message without content")
        }

        switch protocolMessage.syncMessageType {
        case .unknown:
            Logger.peerConnection
                .warning(
                    "received unknown msg \(data) from \(self.endpoint.debugDescription, privacy: .public)"
                )
            return SyncV1Msg.unknown(data)
        case .syncV1data:
            return SyncV1Msg.decode(data)
        }
    }
}
