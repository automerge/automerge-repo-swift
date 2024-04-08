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

        public static let `default` = PeerToPeerProviderConfiguration(
            reconnectOnError: true,
            listening: true,
            peerName: nil
        )
        
        init(reconnectOnError: Bool, listening: Bool, peerName: String?, autoconnect: Bool? = nil) {
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

    public var peeredConnections: [PeerConnection]
    var connections: [PeerToPeerConnection]
    var delegate: (any NetworkEventReceiver)?
    var peerId: PEER_ID?
    var peerMetadata: PeerMetadata?
    // var webSocketTask: URLSessionWebSocketTask?
    // var backgroundWebSocketReceiveTask: Task<Void, any Error>?
    var config: PeerToPeerProviderConfiguration
    var endpoint: NWEndpoint?

    var browser: NWBrowser?
    var listener: NWListener?
    var txtRecord: NWTXTRecord
    
    // listener tasks to process/react to callbacks
    // from NWListener and NWNBrowser
    let stateStream: AsyncStream<NWListener.State>
    let stateContinuation: AsyncStream<NWListener.State>.Continuation
    var listenerStateUpdateTaskHandle: Task<(), Never>?
    
    let newConnectionStream: AsyncStream<NWConnection>
    let newConnectionContinuation: AsyncStream<NWConnection>.Continuation
    var newConnectionTaskHandle: Task<(), Never>?

    public init(_ config: PeerToPeerProviderConfiguration = .default) {
        self.config = config
        connections = []
        peeredConnections = []
        delegate = nil
        peerId = nil
        peerMetadata = nil
        listener = nil
        browser = nil
        var record = NWTXTRecord()
        record[TXTRecordKeys.name] = config.peerName
        record[TXTRecordKeys.peer_id] = "UNCONFIGURED"
        self.txtRecord = record
        
        // AsyncStream as a queue to receive the updates
        let (stateStream, stateContinuation) = AsyncStream<NWListener.State>.makeStream()
        // task handle to have some async process accepting and dealing with the results
        self.stateStream = stateStream
        self.stateContinuation = stateContinuation
        self.listenerStateUpdateTaskHandle = nil
        
        // The system calls this when a new connection arrives at the listener.
        // Start the connection to accept it, or cancel to reject it.
        let (newConnectionStream, newConnectionContinuation) = AsyncStream<NWConnection>.makeStream()
        // task handle to have some async process accepting and dealing with the results
        self.newConnectionStream = newConnectionStream
        self.newConnectionContinuation = newConnectionContinuation
        self.newConnectionTaskHandle = nil

    }
    
    deinit {
        newConnectionTaskHandle?.cancel()
        listenerStateUpdateTaskHandle?.cancel()
        newConnectionTaskHandle = nil
        listenerStateUpdateTaskHandle = nil
    }

    // MARK: NetworkProvider Methods

    public func connect(to _: NWEndpoint) async throws {
        fatalError("Not Yet Implemented")
    }

    public func disconnect() async {
        fatalError("Not Yet Implemented")
    }

    public func send(message _: SyncV1Msg, to _: PEER_ID?) async {
        fatalError("Not Yet Implemented")
    }

    public func setDelegate(_: any NetworkEventReceiver, as _: PEER_ID, with _: PeerMetadata?) async {
        fatalError("Not Yet Implemented")
    }
    
    // extra
    
    public func disconnect(_ peer: PEER_ID) async {
        
    }
    
    public func activate() {
        // if listener = true, set up a listener...
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
                Logger.syncController
                    .info("Bonjour listener ready on \(port.rawValue, privacy: .public)")
            } else {
                Logger.syncController
                    .info("Bonjour listener ready (no port listed)")
            }
        case let .failed(error):
            if error == NWError.dns(DNSServiceErrorType(kDNSServiceErr_DefunctConnection)) {
                Logger.syncController
                    .warning("Bonjour listener failed with \(error, privacy: .public), restarting.")
                listener.cancel()
                self.listener = nil
                self.setupBonjourListener()
            } else {
                Logger.syncController
                    .error("Bonjour listener failed with \(error, privacy: .public), stopping.")
                listener.cancel()
            }
        case .setup:
            break
        case .waiting(_):
            break
        case .cancelled:
            break
        @unknown default:
            break
        }
    }
    
    private func handleNewConnection(_ newConnection: NWConnection) async {
        Logger.syncController
            .debug(
                "Receiving connection request from \(newConnection.endpoint.debugDescription, privacy: .public)"
            )
        Logger.syncController
            .debug(
                "  Connection details: \(newConnection.debugDescription, privacy: .public)"
            )

        var connectionEndpoint: [NWEndpoint] = []
        for connection in connections {
            if let ep = await connection.endpoint {
                connectionEndpoint.append(ep)
            }
        }
        if connectionEndpoint.isEmpty {
            Logger.syncController
                .info(
                    "Endpoint not yet recorded, accepting connection from \(newConnection.endpoint.debugDescription, privacy: .public)"
                )
            let peerConnection = await PeerToPeerConnection(
                connection: newConnection
            )
            connections.append(peerConnection)
        } else {
            Logger.syncController
                .info(
                    "Inbound connection already exists for \(newConnection.endpoint.debugDescription, privacy: .public), cancelling the connection request."
                )
            // If we already have a connection to that endpoint, don't add another
            newConnection.cancel()
        }
    }

    // Start listening and advertising.
    fileprivate func setupBonjourListener() {
        guard let peerId = peerId else {
            // LOG ERROR? THROW ERROR?
            return
        }
        do {
            // Create the listener object.
            let listener = try NWListener(using: NWParameters.peerSyncParameters(passcode: peerId))
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
                for await newConnection in newConnectionStream {
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
            Logger.syncController
                .debug("Starting bonjour network listener")

        } catch {
            Logger.syncController
                .critical("Failed to create bonjour listener")
        }
    }

    // Stop all listeners.
    fileprivate func stopListening() {
        listener?.cancel()
        listener = nil
    }

    // Update the advertised name on the network.
    fileprivate func resetName(_ name: String) {
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
//                        "Updated bonjour network listener to name \(name, privacy: .public) for document id \(documentId, privacy: .public)"
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
