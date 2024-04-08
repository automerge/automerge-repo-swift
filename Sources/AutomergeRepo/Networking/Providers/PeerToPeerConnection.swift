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

struct ReceiveMessageData {
    let content: Data?
    let contentContext: NWConnection.ContentContext?
    let isComplete: Bool
    let error: NWError?
}
/// A peer to peer sync connection to receive and send sync messages.
///
/// As soon as it is established, it attempts to commence a sync operation (send and expect to receive sync messages).
/// In addition, it includes an optional `trigger` in its initializer that, when it receives any signal value, kicks off
/// another attempt to sync the relevant Automerge document.
public actor PeerToPeerConnection {
    
    // A Sendable wrapper around NWConnection to hold async handlers and relevant state
    // for the connection
    
    var connection: NWConnection
    /// A Boolean value that indicates this app initiated this connection.

    var endpoint: NWEndpoint?

    let stateStream: AsyncStream<NWConnection.State>
    let stateContinuation: AsyncStream<NWConnection.State>.Continuation
    var listenerStateUpdateTaskHandle: Task<(), Never>?

    let messageStream: AsyncStream<ReceiveMessageData>
    let receiveMessageContinuation: AsyncStream<ReceiveMessageData>.Continuation
    var receiveMessageTaskHandle: Task<(), Never>?

    /// Initiate a connection to a network endpoint to synchronise an Automerge Document.
    /// - Parameters:
    ///   - endpoint: The endpoint to attempt to connect.
    ///   - delegate: A delegate that can process Automerge sync protocol messages.
    ///   - trigger: A publisher that provides a recurring signal to trigger a sync request.
    ///   - docId: The document Id to use as a pre-shared key in TLS establishment of the connection.
    init(
        endpoint: NWEndpoint,
        passcode: String
    ) async {
        let connection = NWConnection(
            to: endpoint,
            using: NWParameters.peerSyncParameters(passcode: passcode)
        )
        self.connection = connection
        self.endpoint = endpoint
        Logger.syncConnection
            .debug("Initiating connection to \(endpoint.debugDescription, privacy: .public)")
        // AsyncStream as a queue to receive the updates
        let (stream, continuation) = AsyncStream<NWConnection.State>.makeStream()
        // task handle to have some async process accepting and dealing with the results
        listenerStateUpdateTaskHandle = nil

        self.stateStream = stream
        self.stateContinuation = continuation
        // connect into the existing system by yielding the value
        // into the continuation that the stream provided on creation.

        (messageStream, receiveMessageContinuation) = AsyncStream<ReceiveMessageData>.makeStream()
        receiveMessageTaskHandle = Task {
            for await msgData in messageStream {
                await receiveMessageData(msgData)
            }
        }

        connection.stateUpdateHandler = { newState in
            self.stateContinuation.yield(newState)
        }

        // Start the connection establishment.
        connection.start(queue: .main)

    }

    /// Accepts and runs a connection from another network endpoint to synchronise an Automerge Document.
    /// - Parameters:
    ///   - connection: The connection provided by a listener to accept.
    ///   - delegate: A delegate that can process Automerge sync protocol messages.
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

        (messageStream, receiveMessageContinuation) = AsyncStream<ReceiveMessageData>.makeStream()
        receiveMessageTaskHandle = nil

        // connect into the existing system by yielding the value
        // into the continuation that the stream provided on creation.
        connection.stateUpdateHandler = { newState in
            self.stateContinuation.yield(newState)
        }

        receiveMessageTaskHandle = Task {
            for await msgData in messageStream {
                await receiveMessageData(msgData)
            }
        }

        // Start the connection establishment.
        connection.start(queue: .main)
    }

    /// Cancels the current connection.
    public func cancel() {
        connection.cancel()
//        connectionState = .cancelled
//        self.connection = nil
    }

    func handleConnectionStateUpdate(_ newState: NWConnection.State) async {
        switch newState {
        case .ready:
            Logger.syncConnection
                .debug(
                    "connection to \(self.connection.endpoint.debugDescription, privacy: .public) ready."
                )
            // When the connection is ready, start receiving messages.
            receiveNextMessage()

        case let .failed(error):
            Logger.syncConnection
                .warning(
                    "FAILED \(String(describing: self.connection), privacy: .public) : \(error, privacy: .public)"
                )
            // Cancel the connection upon a failure.
            connection.cancel()

        case .cancelled:
            Logger.syncConnection
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
            Logger.syncConnection
                .warning(
                    "connection to \(self.connection.endpoint.debugDescription, privacy: .public) waiting: \(nWError.debugDescription, privacy: .public)."
                )
            
        case .preparing:
            Logger.syncConnection
                .debug(
                    "connection to \(self.connection.endpoint.debugDescription, privacy: .public) preparing."
                )

        case .setup:
            Logger.syncConnection
                .debug(
                    "connection to \(self.connection.endpoint.debugDescription, privacy: .public) in setup."
                )
        default:
            break
        }
    }
    
    /// Receive a message from the sync protocol framing, deliver it to the delegate for processing, and continue
    /// receiving messages.
    private func receiveNextMessage() {
        connection.receiveMessage { content, context, isComplete, error in
            let data = ReceiveMessageData(content: content, contentContext: context, isComplete: isComplete, error: error)
            self.receiveMessageContinuation.yield(data)
        }
    }

    // MARK: Automerge data to Automerge Sync Protocol transforms

    /// Sends an Automerge sync data packet.
    /// - Parameter syncMsg: The data to send.
    func sendMessage(_ syncMsg: Data) {
        // Create a message object to hold the command type.
        let message = NWProtocolFramer.Message(syncMessageType: .sync)
        let context = NWConnection.ContentContext(
            identifier: "Sync",
            metadata: [message]
        )

        // Send the app content along with the message.
        connection.send(
            content: syncMsg,
            contentContext: context,
            isComplete: true,
            completion: .idempotent
        )
    }

    func receiveMessageData(_ data: ReceiveMessageData) async {
        Logger.syncConnection
            .debug(
                "Received a \(data.isComplete ? "complete" : "incomplete", privacy: .public) msg on connection"
            )
        if let bytes = data.content?.count {
            Logger.syncConnection.debug("  - received \(bytes) bytes")
        } else {
            Logger.syncConnection.debug("  - received no data with msg")
        }
        // Extract your message type from the received context.
        if let protocolMessage = data.contentContext?
            .protocolMetadata(definition: P2PAutomergeSyncProtocol.definition) as? NWProtocolFramer.Message,
           let currentEndpoint = endpoint
        {
            self.handleProtocolMessage(content: data.content, message: protocolMessage, from: currentEndpoint)
        }
        if data.error != nil {
            Logger.syncConnection.error("  - error on received message: \(data.error)")
            self.cancel()
        }
    }
    
    func handleProtocolMessage(content data: Data?, message: NWProtocolFramer.Message, from endpoint: NWEndpoint) {
//        guard let document = DocumentSyncCoordinator.shared.documents[documentId]?.value else {
//            Logger.syncConnection
//                .warning(
//                    "\(self.shortId, privacy: .public): received msg for unregistered document \(self.documentId, privacy: .public) from \(endpoint.debugDescription, privacy: .public)"
//                )
//
//            return
//        }
//        switch message.syncMessageType {
//        case .unknown:
//            Logger.syncConnection
//                .error(
//                    "\(self.shortId, privacy: .public): Invalid message received from \(endpoint.debugDescription, privacy: .public)"
//                )
//        case .sync:
//            guard let data else {
//                Logger.syncConnection
//                    .error(
//                        "\(self.shortId, privacy: .public): Sync message received without data from \(endpoint.debugDescription, privacy: .public)"
//                    )
//                return
//            }
//            do {
//                // When we receive a complete sync message from the underlying transport,
//                // update our automerge document, and the associated SyncState.
//                let patches = try document.receiveSyncMessageWithPatches(
//                    state: syncState,
//                    message: data
//                )
//                Logger.syncConnection
//                    .debug(
//                        "\(self.shortId, privacy: .public): Received \(patches.count, privacy: .public) patches in \(data.count, privacy: .public) bytes"
//                    )
//
//                // Once the Automerge doc is updated, check (using the SyncState) to see if
//                // we believe we need to send additional messages to the peer to keep it in sync.
//                if let response = document.generateSyncMessage(state: syncState) {
//                    sendSyncMsg(response)
//                } else {
//                    // When generateSyncMessage returns nil, the remote endpoint represented by
//                    // SyncState should be up to date.
//                    Logger.syncConnection
//                        .debug(
//                            "\(self.shortId, privacy: .public): Sync complete with \(endpoint.debugDescription, privacy: .public)"
//                        )
//                }
//            } catch {
//                Logger.syncConnection
//                    .error("\(self.shortId, privacy: .public): Error applying sync message: \(error, privacy: .public)")
//            }
//        case .id:
//            Logger.syncConnection.info("\(self.shortId, privacy: .public): received request for document ID")
//            sendDocumentId(documentId)
//        case .peer:
//            break
//        case .leave:
//            break
//        case .join:
//            break
//        case .request:
//            break
//        case .unavailable:
//            break
//        case .ephemeral:
//            break
//        case .syncerror:
//            break
//        case .remoteHeadsChanged:
//            break
//        case .remoteSubscriptionChange:
//            break
//        }
    }
}
