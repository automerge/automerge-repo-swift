// import AsyncAlgorithms
internal import Automerge
internal import struct Foundation.Data
internal import OSLog
internal import PotentCBOR

// riff
// https://github.com/automerge/automerge-repo/blob/main/packages/automerge-repo/src/network/NetworkSubsystem.ts

/// A type that hosts network subsystems to connect to peers.
///
/// The NetworkSubsystem instance is responsible for setting up and configuring any network providers, and responding to
/// messages from remote peers after the connection has been established. The connection handshake and peer negotiation
/// is
/// the responsibility of the network provider instance.
@AutomergeRepo
final class NetworkSubsystem {
    // TODO: When swift allows, switch this to a class that's locked to the same local actor
    // as Repo

    // a list of documents with a pending request for a documentId
    var requestedDocuments: [DocumentId: [PEER_ID]] = [:]

    public static let encoder = CBOREncoder()
    public static let decoder = CBORDecoder()

    // repo is a weak var to avoid a retain cycle - a network subsystem is
    // (so far) always created with a Repo and uses it for remote data storage of documents that
    // it fetches, syncs, or gossips about.
    //
    // TODO: revisit this and consider if the callbacks to repo should be exposed as a delegate
    weak var repo: Repo?
    var adapters: [any NetworkProvider]
    var loglevel: LogVerbosity

    nonisolated init(verbosity: LogVerbosity) {
        adapters = []
        self.loglevel = verbosity
    }

    func setRepo(_ repo: Repo) {
        self.repo = repo
    }

    func setLogVerbosity(_ level: LogVerbosity) {
        self.loglevel = level
    }

    func addAdapter(adapter: some NetworkProvider) {
        guard let peerId = repo?.peerId else {
            fatalError("NO REPO CONFIGURED WHEN ADDING ADAPTERS")
        }
        adapter.setDelegate(self, as: peerId, with: repo?.localPeerMetadata)
        adapters.append(adapter)
    }

    func startRemoteFetch(id: DocumentId) async throws {
        // attempt to fetch the provided document Id from all (current) peers, returning the document
        // or returning nil if the document is unavailable.
        // Save the throwing scenarios for failures in connection, etc.
        guard let repo else {
            // invariant that there should be a valid doc handle available from the repo
            throw Errors.Unavailable(id: id)
        }
        if loglevel.canTrace() {
            Logger.network.trace("REPONET: Initiating remote fetch for \(id)")
        }
        let newDocument = Document()
        requestedDocuments[id] = []
        for adapter in adapters {
            for peerConnection in adapter.peeredConnections {
                if loglevel.canTrace() {
                    Logger.network
                        .trace(
                            "REPONET: requesting \(id) from peer \(peerConnection.peerId) at \(peerConnection.endpoint)"
                        )
                }
                // upsert the requested document into the list by peer
                if var existingList = requestedDocuments[id] {
                    existingList.append(peerConnection.peerId)
                    requestedDocuments[id] = existingList
                }
                // get a current sync state (creating one if needed for a fresh sync)
                let syncState = repo.syncState(id: id, peer: peerConnection.peerId)

                if let syncRequestData = newDocument.generateSyncMessage(state: syncState) {
                    await adapter.send(message: .request(SyncV1Msg.RequestMsg(
                        documentId: id.description,
                        senderId: repo.peerId,
                        targetId: peerConnection.peerId,
                        sync_message: syncRequestData
                    )), to: peerConnection.peerId)
                }
            }
        }
        guard let allRequestedPeers = requestedDocuments[id], !allRequestedPeers.isEmpty else {
            Logger.network
                .error("Finishing remote fetch without any active network requests to peers, reporting Unavailable")
            throw Errors.Unavailable(id: id)
        }
        if loglevel.canTrace() {
            Logger.network.trace("REPONET: remote fetch for \(id) finished")
        }
    }

    func send(message: SyncV1Msg, to: PEER_ID?) async {
        for adapter in adapters {
            if loglevel.canTrace() {
                Logger.network
                    .trace("REPONET: sending message on \(String(describing: adapter)) to \(String(describing: to))")
            }
            await adapter.send(message: message, to: to)
        }
    }
}

extension NetworkSubsystem: NetworkEventReceiver {
    // Collection point for messages coming in from all network adapters.
    // The network subsystem forwards messages from network peers to the relevant places,
    // and forwards messages out to peers as needed
    //
    // In automerge-repo code, it appears to update information on an ephemeral information (
    // a sort of middleware) before emitting it upwards.
    public func receiveEvent(event: NetworkAdapterEvents) async {
        if loglevel.canTrace() {
            Logger.network.trace("REPONET: received event from network adapter: \(event.debugDescription)")
        }
        guard let repo else {
            // No-op if there's no repo to update state or handle
            // further message passing
            return
        }
        switch event {
        case let .ready(payload):
            await repo.addPeerWithMetadata(peer: payload.peerId, metadata: payload.peerMetadata)
        case .close:
            break
        // attempt to reconnect, or remove from active adapters?
        case let .peerCandidate(payload):
            await repo.addPeerWithMetadata(peer: payload.peerId, metadata: payload.peerMetadata)
        case let .peerDisconnect(payload):
            repo.removePeer(peer: payload.peerId)
        case let .message(payload):
            switch payload {
            case .peer, .join, .leave, .unknown:
                // ERROR FOR THESE MSG TYPES - expected to be handled at adapter
                Logger.network
                    .error(
                        "REPONET: Unexpected message type received by network subsystem: \(payload.debugDescription, privacy: .public)"
                    )
                #if DEBUG
                fatalError("UNEXPECTED MSG")
                #endif
            case let .error(errorMsg):
                Logger.network
                    .warning(
                        "REPONET: Error message received by network subsystem: \(errorMsg.debugDescription, privacy: .public)"
                    )
            case let .request(requestMsg):
                await repo.handleRequest(msg: requestMsg)
            case let .sync(syncMsg):
                await repo.handleSync(msg: syncMsg)
            case let .unavailable(unavailableMsg):
                guard let docId = DocumentId(unavailableMsg.documentId) else {
                    Logger.network
                        .error(
                            "REPONET: Invalid message Id \(unavailableMsg.documentId, privacy: .public) in unavailable msg: \(unavailableMsg.debugDescription, privacy: .public)"
                        )
                    return
                }
                if loglevel.canTrace() {
                    Logger.network.trace("REPONET: Received \(event.debugDescription) event")
                }
                if let peersRequested = requestedDocuments[docId] {
                    if loglevel.canTrace() {
                        Logger.network.trace("REPONET: We've requested \(docId) from \(peersRequested.count) peers:")
                        for p in peersRequested {
                            Logger.network.trace("REPONET: - Peer: \(p)")
                        }
                    }
                    // if we receive an unavailable from one peer, record it and wait until
                    // we receive unavailable from all available peers before marking it unavailable
                    let remainingPeersPending = peersRequested.filter { peerId in
                        // include the peers OTHER than the one sending the unavailable msg
                        peerId != unavailableMsg.senderId
                    }
                    if loglevel.canTrace() {
                        Logger.network
                            .trace(
                                "REPONET: Removing the sending peer, there are \(remainingPeersPending.count) remaining:"
                            )

                        for p in remainingPeersPending {
                            Logger.network.trace("REPONET: - Peer: \(p)")
                        }
                    }
                    if remainingPeersPending.isEmpty {
                        if loglevel.canTrace() {
                            Logger.network
                                .trace(
                                    "REPONET: No further peers with requests outstanding, so marking document \(docId) as unavailable"
                                )
                        }
                        await repo.markDocUnavailable(id: docId)
                        requestedDocuments.removeValue(forKey: docId)
                    } else {
                        // handle the scenario where we started with more adapters but
                        // lost a connection...

                        var currentConnectedPeers: [PEER_ID] = []
                        for adapter in adapters {
                            let connectedPeers: [PEER_ID] = adapter.peeredConnections
                                .map { peerConnection in
                                    peerConnection.peerId
                                }
                            currentConnectedPeers.append(contentsOf: connectedPeers)
                        }
                        let stillPending = remainingPeersPending.compactMap { peerId in
                            if currentConnectedPeers.contains(peerId) {
                                peerId
                            } else {
                                nil
                            }
                        }
                        // save the data back for other adapters to respond later...
                        requestedDocuments[docId] = stillPending
                    }
                } else {
                    // no peers are waiting to hear about a requested document, ignore
                    return
                }
            case let .ephemeral(ephemeralMsg):
                Logger.network
                    .error(
                        "REPONET: UNIMPLEMENTED EPHEMERAL MESSAGE PASSING: \(ephemeralMsg.debugDescription, privacy: .public)"
                    )
            case let .remoteSubscriptionChange(remoteSubscriptionChangeMsg):
                Logger.network
                    .error(
                        "REPONET: UNIMPLEMENTED EPHEMERAL MESSAGE PASSING: \(remoteSubscriptionChangeMsg.debugDescription, privacy: .public)"
                    )
            case let .remoteHeadsChanged(remoteHeadsChangedMsg):
                Logger.network
                    .error(
                        "REPONET: UNIMPLEMENTED EPHEMERAL MESSAGE PASSING: \(remoteHeadsChangedMsg.debugDescription, privacy: .public)"
                    )
            }
        }
    }
}
