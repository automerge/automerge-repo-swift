import Automerge
import AutomergeUtilities
import Combine
import Foundation
import OSLog

/// A type that accepts ephemeral messages as they arrive from connected network peers.
public protocol EphemeralMessageDelegate: Sendable {
    /// Receive and process an event from a Network Provider.
    /// - Parameter event: The event to process.
    func receiveEphemeralMessage(_ msg: SyncV1Msg.EphemeralMsg) async
}

@AutomergeRepo
public final class Repo {
    public nonisolated let peerId: PEER_ID
    public var localPeerMetadata: PeerMetadata

    private var handles: [DocumentId: InternalDocHandle] = [:]
    private var storage: DocumentStorage?
    private var network: NetworkSubsystem

    // saveDebounceRate = 100
    var sharePolicy: any ShareAuthorizing

    /** maps peer id to to persistence information (storageId, isEphemeral), access by collection synchronizer  */
    /** @hidden */
    private var peerMetadataByPeerId: [PEER_ID: PeerMetadata] = [:]

    private let maxRetriesForFetch: Int = 300
    private let pendingRequestWaitDuration: Duration = .seconds(1)
    private var pendingRequestReadAttempts: [DocumentId: Int] = [:]

    private var remoteHeadsGossipingEnabled = false

    private var _ephemeralMessageDelegate: (any EphemeralMessageDelegate)?

    // TESTING HOOKS - for receiving state updates while testing
    nonisolated let docHandlePublisher: PassthroughSubject<InternalDocHandle.DocHandleSnapshot, Never> = PassthroughSubject()

    // REPO
    // https://github.com/automerge/automerge-repo/blob/main/packages/automerge-repo/src/Repo.ts
    // - looks like it's the rough equivalent to the overall synchronization coordinator

    // - owns synchronizer, network, and storage subsystems
    // - it "just" manages the connections, adds, and removals - when documents "appear", they're
    // added to the synchronizer, which is the thing that accepts sync messages and tries to keep documents
    // up to date with any registered peers. It emits (at a debounced rate) events to let anyone watching
    // a document know that changes have occurred.
    //
    // Looks like it also has the idea of a sharePolicy per document, and if provided, then a document
    // will be shared with peers (or positively respond to requests for the document if it's requested)

    // Repo
    //  property: peers [PeerId] - all (currently) connected peers
    //  property: handles [DocHandle] - list of all the DocHandles
    // - func clone(Document) -> Document
    // - func export(DocumentId) -> uint8[]
    // - func import(uint8[]) -> Document
    // - func create() -> Document
    // - func find(DocumentId) -> Document
    // - func delete(DocumentId)
    // - func storageId() -> StorageId (async)
    // - func storageIdForPeer(peerId) -> StorageId
    // - func subscribeToRemotes([StorageId])

    /// Create a new repository with the share policy you provide
    /// - Parameter sharePolicy: The policy to use to determine if a repository shares a document.
    public nonisolated init(
        sharePolicy: SharePolicy
    ) {
        peerId = UUID().uuidString
        storage = nil
        localPeerMetadata = PeerMetadata(storageId: nil, isEphemeral: true)
        self.sharePolicy = sharePolicy as any ShareAuthorizing
        network = NetworkSubsystem()
    }

    /// Create a new repository with the share policy and storage provider that you provide.
    /// - Parameter sharePolicy: The policy to use to determine if a repository shares a document.
    /// - Parameter storage: The storage provider for the repository.
    public nonisolated init(
        sharePolicy: SharePolicy,
        storage: some StorageProvider
    ) {
        peerId = UUID().uuidString
        self.sharePolicy = sharePolicy as any ShareAuthorizing
        network = NetworkSubsystem()
        self.storage = DocumentStorage(storage)
        localPeerMetadata = PeerMetadata(storageId: storage.id, isEphemeral: false)
    }

    /// Create a new repository with the share policy and storage provider that you provide.
    /// - Parameters:
    ///   - sharePolicy: The policy to use to determine if a repository shares a document.
    ///   - storage: The storage provider for the repository.
    ///   - networks: A list of network providers to add.
    public init(
        sharePolicy: SharePolicy,
        storage: some StorageProvider,
        networks _: [any NetworkProvider]
    ) {
        self.sharePolicy = sharePolicy as any ShareAuthorizing
        peerId = UUID().uuidString
        self.storage = DocumentStorage(storage)
        localPeerMetadata = PeerMetadata(storageId: storage.id, isEphemeral: false)
        network = NetworkSubsystem()
        network.setRepo(self)
        for adapter in network.adapters {
            network.addAdapter(adapter: adapter)
        }
    }

    /// Add a configured network provider to the repo
    /// - Parameter adapter: The network provider to add.
    public func addNetworkAdapter(adapter: any NetworkProvider) {
        if network.repo == nil {
            network.setRepo(self)
        }
        network.addAdapter(adapter: adapter)
    }

    /// Set the delegate that to receive ephemeral messages from Automerge-repo peers
    /// - Parameter delegate: The object that Automerge-repo calls with ephemeral messages.
    public func setDelegate(_ delegate: some EphemeralMessageDelegate) {
        _ephemeralMessageDelegate = delegate
    }

    /// Returns a list of repository documentIds.
    ///
    /// The list does not reflect deleted or unavailable documents that have been requested, but may return
    /// Ids for documents still being creating, stored, or transferring from a peer.
    public func documentIds() -> [DocumentId] {
        // FIXME: make sure that the handles are all fully "resolved" to an end state
        // _before_ attempting to filter them - we're capturing a snapshot in time here...
        handles.values
            .filter { handle in
                handle.state == .ready || handle.state == .loading || handle.state == .requesting
            }
            .map(\.id)
    }

    // MARK: Synchronization Pieces - Peers

    /// Returns a list of the ids of available peers.
    public func peers() -> [PEER_ID] {
        peerMetadataByPeerId.keys.sorted()
    }

    /// Returns the storage Id of for the id of the peer that you provide.
    /// - Parameter peer: The peer to request
    func getStorageIdOfPeer(peer: PEER_ID) -> STORAGE_ID? {
        if let metaForPeer = peerMetadataByPeerId[peer] {
            metaForPeer.storageId
        } else {
            nil
        }
    }

    func beginSync(docId: DocumentId, to peer: PEER_ID) async {
        do {
            let handle = try await resolveDocHandle(id: docId)
            let syncState = syncState(id: docId, peer: peer)
            if let syncData = handle.doc.generateSyncMessage(state: syncState) {
                let syncMsg: SyncV1Msg = .sync(.init(
                    documentId: docId.description,
                    senderId: peerId,
                    targetId: peer,
                    sync_message: syncData
                ))
                await network.send(message: syncMsg, to: peer)
            }
        } catch {
            Logger.repo
                .error(
                    "REPO: \(self.peerId) Failed to generate sync on peer connection: \(error.localizedDescription, privacy: .public)"
                )
        }
    }

    func addPeerWithMetadata(peer: PEER_ID, metadata: PeerMetadata?) async {
        assert(peer != self.peerId)
        peerMetadataByPeerId[peer] = metadata
        Logger.repo.trace("REPO: \(self.peerId) adding peer \(peer)")
        for docId in documentIds() {
            if await sharePolicy.share(peer: peer, docId: docId) {
                Logger.repo.trace("REPO: \(self.peerId) starting a sync for document \(docId) to \(peer)")
                await beginSync(docId: docId, to: peer)
            } else {
                Logger.repo.trace("REPO: \(self.peerId) SharePolicy DENIED sharing document \(docId) to \(peer)")
            }
        }
    }

    func removePeer(peer: PEER_ID) {
        peerMetadataByPeerId.removeValue(forKey: peer)
    }

    // MARK: Handle pass-back of Ephemeral Messages

    func handleEphemeralMessage(_ msg: SyncV1Msg.EphemeralMsg) async {
        await _ephemeralMessageDelegate?.receiveEphemeralMessage(msg)
    }

    // MARK: Synchronization Pieces - For Network Subsystem Access

    func handleSync(msg: SyncV1Msg.SyncMsg) async {
        Logger.repo.trace("PEER: \(self.peerId) - handling a sync msg from \(msg.senderId) to \(msg.targetId)")
        guard let docId = DocumentId(msg.documentId) else {
            Logger.repo
                .warning("Invalid documentId \(msg.documentId) received in a sync message \(msg.debugDescription)")
            return
        }
        Logger.repo.trace(" - Sync request received for document \(docId)")
        do {
            if handles[docId] == nil {
                Logger.repo.trace(" - No recorded handle for \(docId), creating one")
                // There is no in-memory handle for the document being synced, so this is a request
                // to create a local copy of the document encapsulated in the sync message.
                let newDocument = Document()
                let newHandle = InternalDocHandle(id: docId, isNew: true, initialValue: newDocument)
                docHandlePublisher.send(newHandle.snapshot())
                // must update the repo with the new handle and empty document _before_
                // using syncState, since it needs to resolve the documentId
                handles[docId] = newHandle
                _ = try await resolveDocHandle(id: docId)
            }
            guard let handle = handles[docId] else { fatalError("HANDLE DOESN'T EXIST") }
            Logger.repo.trace(" - working on handle for \(docId), state: \(String(describing: handle.state))")
            let docFromHandle = handle.doc ?? Document()
            let syncState = syncState(id: docId, peer: msg.senderId)
            // Apply the request message as a sync update
            try docFromHandle.receiveSyncMessage(state: syncState, message: msg.data)
            // Stash the updated document and sync state
            await updateDoc(id: docId, doc: docFromHandle)
            await updateSyncState(id: docId, peer: msg.senderId, syncState: syncState)
            // Attempt to generate a sync message to reply

            // DEBUG ONLY
            // print("\(self.peerId): STATE OF \(handle.id)")
            // try docFromHandle.walk()

            if let syncData = docFromHandle.generateSyncMessage(state: syncState) {
                let syncMsg: SyncV1Msg = .sync(.init(
                    documentId: docId.description,
                    senderId: peerId,
                    targetId: msg.senderId,
                    sync_message: syncData
                ))
                Logger.repo.trace("Sync received and applied, replying with a sync msg back to \(msg.senderId)")
                await network.send(message: syncMsg, to: msg.senderId)
            }
            // else no sync is needed, as the last sync state reports that it knows about
            // all the changes it needs - that it's up to date with the local document
        } catch {
            let err: SyncV1Msg =
                .error(.init(message: "Error receiving sync: \(error.localizedDescription)"))
            Logger.repo.warning("Error receiving initial sync for \(docId, privacy: .public)")
            await network.send(message: err, to: msg.senderId)
        }
    }

    func handleRequest(msg: SyncV1Msg.RequestMsg) async {
        guard let docId = DocumentId(msg.documentId) else {
            Logger.repo
                .warning("Invalid documentId \(msg.documentId) received in a sync message \(msg.debugDescription)")
            return
        }
        if handles[docId] != nil {
            // If we have the document, see if we're agreeable to sending a copy
            if await sharePolicy.share(peer: msg.senderId, docId: docId) {
                do {
                    let handle = try await resolveDocHandle(id: docId)
                    let syncState = syncState(id: docId, peer: msg.senderId)
                    // Apply the request message as a sync update
                    try handle.doc.receiveSyncMessage(state: syncState, message: msg.data)
                    // Stash the updated doc and sync state
                    await updateDoc(id: docId, doc: handle.doc)
                    await updateSyncState(id: docId, peer: msg.senderId, syncState: syncState)
                    // Attempt to generate a sync message to reply
                    if let syncData = handle.doc.generateSyncMessage(state: syncState) {
                        let syncMsg: SyncV1Msg = .sync(.init(
                            documentId: docId.description,
                            senderId: peerId,
                            targetId: msg.senderId,
                            sync_message: syncData
                        ))
                        await network.send(message: syncMsg, to: msg.senderId)
                    } // else no sync is needed, syncstate reports that they have everything they need
                } catch {
                    let err: SyncV1Msg =
                        .error(.init(message: "Unable to resolve document: \(error.localizedDescription)"))
                    await network.send(message: err, to: msg.senderId)
                }
            } else {
                let nope = SyncV1Msg.UnavailableMsg(
                    documentId: msg.documentId,
                    senderId: peerId,
                    targetId: msg.senderId
                )
                await network.send(message: .unavailable(nope), to: msg.senderId)
            }

        } else {
            let nope = SyncV1Msg.UnavailableMsg(
                documentId: msg.documentId,
                senderId: peerId,
                targetId: msg.senderId
            )
            await network.send(message: .unavailable(nope), to: msg.senderId)
        }
    }

    // MARK: PUBLIC API

    /// Creates a new Automerge document, storing it and sharing the creation with connected peers.
    /// - Returns: The Automerge document.
    public func create() async throws -> DocHandle {
        let handle = InternalDocHandle(id: DocumentId(), isNew: true, initialValue: Document())
        handles[handle.id] = handle
        docHandlePublisher.send(handle.snapshot())
        let resolved = try await resolveDocHandle(id: handle.id)
        return resolved
    }

    /// Creates a new Automerge document, storing it and sharing the creation with connected peers.
    /// - Returns: The Automerge document.
    /// - Parameter id: The Id of the Automerge document.
    public func create(id: DocumentId) async throws -> DocHandle {
        let handle = InternalDocHandle(id: id, isNew: true, initialValue: Document())
        handles[handle.id] = handle
        docHandlePublisher.send(handle.snapshot())
        let resolved = try await resolveDocHandle(id: handle.id)
        return resolved
    }

    /// Creates a new Automerge document, storing it and sharing the creation with connected peers.
    /// - Parameter doc: The Automerge document to use for the new, shared document
    /// - Returns: The Automerge document.
    public func create(doc: Document, id: DocumentId? = nil) async throws -> DocHandle {
        let creationId = id ?? DocumentId()
        let handle = InternalDocHandle(id: creationId, isNew: true, initialValue: doc)
        handles[handle.id] = handle
        docHandlePublisher.send(handle.snapshot())
        let resolved = try await resolveDocHandle(id: handle.id)
        return resolved
    }

    /// Creates a new Automerge document, storing it and sharing the creation with connected peers.
    /// - Parameter data: The data to load as an Automerge document for the new, shared document.
    /// - Returns: The Automerge document.
    public func create(data: Data, id: DocumentId? = nil) async throws -> DocHandle {
        let creationId = id ?? DocumentId()
        let handle = try InternalDocHandle(id: creationId, isNew: true, initialValue: Document(data))
        handles[handle.id] = handle
        docHandlePublisher.send(handle.snapshot())
        let resolved = try await resolveDocHandle(id: handle.id)
        return resolved
    }

    /// Clones a document the repo already knows to create a new, shared document.
    /// - Parameter id: The id of the document to clone.
    /// - Returns: The Automerge document.
    public func clone(id: DocumentId) async throws -> DocHandle {
        let handle = try await resolveDocHandle(id: id)
        let fork = handle.doc.fork()
        let newId = DocumentId()
        let newHandle = InternalDocHandle(id: newId, isNew: false, initialValue: fork)
        handles[newHandle.id] = newHandle
        docHandlePublisher.send(newHandle.snapshot())
        let resolved = try await resolveDocHandle(id: newHandle.id)
        return resolved
    }

    public func find(id: DocumentId) async throws -> DocHandle {
        // generally of the idea that we'll drive DocHandle state updates from within Repo
        // and these async methods
        let handle: InternalDocHandle
        if let knownHandle = handles[id] {
            handle = knownHandle
        } else {
            let newHandle = InternalDocHandle(id: id, isNew: false)
            handles[id] = newHandle
            docHandlePublisher.send(newHandle.snapshot())
            handle = newHandle
        }
        return try await resolveDocHandle(id: handle.id)
    }

    /// Deletes an automerge document from the repo.
    /// - Parameter id: The id of the document to remove.
    ///
    /// > NOTE: deletes do not propagate to connected peers.
    public func delete(id: DocumentId) async throws {
        guard let originalDocHandle = handles[id] else {
            throw Errors.Unavailable(id: id)
        }
        originalDocHandle.state = .deleted
        originalDocHandle.doc = nil
        docHandlePublisher.send(originalDocHandle.snapshot())

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.purgeFromStorage(id: id)
            }
            // specifically call/wait in case we get an error from
            // the delete process in purging the document.
            try await group.next()
        }
    }

    /// Export the data associated with an Automerge document from the repo.
    /// - Parameter id: The id of the document to export.
    /// - Returns: The latest, compacted data of the Automerge document.
    public func export(id: DocumentId) async throws -> Data {
        let handle = try await resolveDocHandle(id: id)
        return handle.doc.save()
    }

    /// Imports data as a new Automerge document
    /// - Parameter data: The data to import as an Automerge document
    /// - Returns: The id of the document that was created on import.
    public func `import`(data: Data) async throws -> DocHandle {
        let handle = try InternalDocHandle(id: DocumentId(), isNew: true, initialValue: Document(data))
        handles[handle.id] = handle
        docHandlePublisher.send(handle.snapshot())
        return try await resolveDocHandle(id: handle.id)
    }

    public func subscribeToRemotes(remotes _: [STORAGE_ID]) async {}

    /// The storage id of this repo, if any.
    /// - Returns: The storage id from the repo's storage provider or nil.
    public func storageId() -> STORAGE_ID? {
        if let storage {
            return storage.id
        }
        return nil
    }

    // MARK: Methods to expose retrieving DocHandles to the subsystems

    func syncState(id: DocumentId, peer: PEER_ID) -> SyncState {
        guard let handle = handles[id] else {
            fatalError("No stored dochandle for id: \(id)")
        }
        if let handleSyncState = handle.syncStates[peer] {
            Logger.repo.trace("Providing stored sync state for doc \(id)")
            return handleSyncState
        } else {
            // TODO: add attempt to load from storage and return it before creating a new one
            Logger.repo.trace("No stored sync state for doc \(id) and peer \(peer).")
            Logger.repo.trace("Creating a new sync state for doc \(id)")
            return SyncState()
        }
    }

    func updateSyncState(id: DocumentId, peer: PEER_ID, syncState: SyncState) async {
        guard let handle = handles[id] else {
            fatalError("No stored dochandle for id: \(id)")
        }
        Logger.repo.trace("Storing updated sync state for doc \(id) and peer \(peer).")
        handle.syncStates[peer] = syncState
    }

    func markDocUnavailable(id: DocumentId) async {
        // handling a requested document being marked as unavailable after all peers have been checked
        guard let handle = handles[id] else {
            Logger.repo.error("missing handle for documentId \(id.description) while attempt to mark unavailable")
            return
        }
        assert(handle.state == .requesting)
        handle.state = .unavailable
        docHandlePublisher.send(handle.snapshot())
    }

    func updateDoc(id: DocumentId, doc: Document) async {
        // handling a requested document being marked as ready after document contents received
        guard let handle = handles[id] else {
            fatalError("No stored document handle for document id: \(id)")
        }
        Logger.repo.trace("Updated contents of document \(id), state: \(String(describing: handle.state))")
        // Automerge-repo https://github.com/automerge/automerge-repo/issues/343 is sending two responses,
        // the first being UNAVAILABLE, which we use to change the state, but that triggers this unexpected
        // assertion, we we later receive the SYNC update to set the document as expected
        assert(handle.state == .ready || handle.state == .unavailable || handle.state == .requesting)
        handle.doc = doc
        handle.state = .ready
        docHandlePublisher.send(handle.snapshot())
        if let storage {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await storage.saveDoc(id: id, doc: doc)
                    }
                    // specifically call/wait in case we get an error from
                    // the delete process in purging the document.
                    try await group.next()
                }
            } catch {
                Logger.repo
                    .warning(
                        "Error received while attempting to store document ID \(id): \(error.localizedDescription)"
                    )
            }
        }
    }

    // MARK: Methods to resolve docHandles

    func merge(id: DocumentId, with: DocumentId) async throws {
        guard let handle1 = handles[id] else {
            throw Errors.DocUnavailable(id: id)
        }
        guard let handle2 = handles[with] else {
            throw Errors.DocUnavailable(id: with)
        }

        let doc1 = try await resolveDocHandle(id: handle1.id)
        // Start with updating from storage changes, if any
        if let doc1Storage = try await storage?.loadDoc(id: handle1.id) {
            try doc1.doc.merge(other: doc1Storage)
        }

        // merge in the provided second document from memory
        let doc2 = try await resolveDocHandle(id: handle2.id)
        try doc1.doc.merge(other: doc2.doc)

        // JUST IN CASE, try and load doc2 from storage and merge that if available
        if let doc2Storage = try await storage?.loadDoc(id: handle2.id) {
            try doc1.doc.merge(other: doc2Storage)
        }
        // finally, update the repo
        await updateDoc(id: doc1.id, doc: doc1.doc)
    }

    private func loadFromStorage(id: DocumentId) async throws -> Document? {
        guard let storage else {
            return nil
        }
        return try await storage.loadDoc(id: id)
    }

    private func purgeFromStorage(id: DocumentId) async throws {
        guard let storage else {
            return
        }
        try await storage.purgeDoc(id: id)
    }

    private func resolveDocHandle(id: DocumentId) async throws -> DocHandle {
        if let handle: InternalDocHandle = handles[id] {
            Logger.resolver.trace("RESOLVE document id \(id) [\(String(describing: handle.state))]")
            switch handle.state {
            case .idle:
                if handle.doc != nil {
                    // if there's an Automerge document in memory, jump to ready
                    handle.state = .ready
                    Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                    // STRUCT ONLY handles[id] = handle
                } else {
                    // otherwise, first attempt to load it from persistent storage
                    // (if available)
                    handle.state = .loading
                    Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                    // STRUCT ONLY handles[id] = handle
                }
                Logger.resolver.trace("RESOLVE: :: continuing to resolve")
                docHandlePublisher.send(handle.snapshot())
                return try await resolveDocHandle(id: id)
            case .loading:
                // Do we have the document
                if let docFromHandle = handle.doc {
                    // We have the document - so being in loading means "try to save this to
                    // a storage provider, if one exists", then hand it back as good.
                    if let storage {
                        await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask {
                                try await storage.saveDoc(id: id, doc: docFromHandle)
                            }
                            // DO NOT wait/see if there's an error in the repo attempting to
                            // store the document - this gives us a bit of "best effort" functionality
                            // TODO: consider making this a parameter, or review this choice before release
                            // specifically call/wait in case we get an error from
                            // the delete process in purging the document.
                            // try await group.next()
                            //
                            // if we want to change this, uncomment the `try await` above and
                            // convert the `withThrowingTaskGroup` to `try await` as well.
                        }
                    }
                    // TODO: if we're allowed and prolific in gossip, notify any connected
                    // peers there's a new document before jumping to the 'ready' state
                    handle.state = .ready
                    docHandlePublisher.send(handle.snapshot())
                    Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                    return DocHandle(id: id, doc: docFromHandle)
                } else {
                    // We don't have the underlying Automerge document, so attempt
                    // to load it from storage, and failing that - if the storage provider
                    // doesn't exist, for example - jump forward to attempting to fetch
                    // it from a peer.
                    if let doc = try await loadFromStorage(id: id) {
                        handle.state = .ready
                        docHandlePublisher.send(handle.snapshot())
                        Logger.resolver.trace("RESOLVED! :: \(id) -> [\(String(describing: handle.state))]")
                        return DocHandle(id: id, doc: doc)
                    } else {
                        handle.state = .requesting
                        pendingRequestReadAttempts[id] = 0
                        Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                        Logger.resolver.trace("RESOLVE: :: starting remote fetch")
                        try await network.startRemoteFetch(id: handle.id)
                        Logger.resolver.trace("RESOLVE: :: continuing to resolve")
                        docHandlePublisher.send(handle.snapshot())
                        return try await resolveDocHandle(id: id)
                    }
                }
            case .requesting:
                guard let updatedHandle = handles[id] else {
                    Logger.resolver.trace("RESOLVED - X :: Missing \(id) -> [UNAVAILABLE]")
                    throw Errors.DocUnavailable(id: handle.id)
                }
                if let doc = updatedHandle.doc, updatedHandle.state == .ready {
                    Logger.resolver.trace("RESOLVED! :: \(id) -> [\(String(describing: handle.state))]")
                    return DocHandle(id: id, doc: doc)
                } else {
                    guard let previousRequests = pendingRequestReadAttempts[id] else {
                        Logger.resolver
                            .trace("RESOLVED - X :: Missing \(id) from pending request read attempts -> [UNAVAILABLE]")
                        throw Errors.DocUnavailable(id: id)
                    }
                    if previousRequests < maxRetriesForFetch {
                        // we are racing against the receipt of a network result
                        // to see what we get at the end
                        Logger.resolver.trace(" :: \(id) -> [\(String(describing: handle.state))]")
                        Logger.resolver
                            .trace(
                                " :: check # \(previousRequests) (of \(self.maxRetriesForFetch), waiting \(self.pendingRequestWaitDuration) seconds for remote fetch"
                            )
                        try await Task.sleep(for: pendingRequestWaitDuration)
                        pendingRequestReadAttempts[id] = previousRequests + 1
                        Logger.resolver.trace("RESOLVE: :: continuing to resolve")
                        return try await resolveDocHandle(id: id)
                    } else {
                        updatedHandle.state = .unavailable
                        docHandlePublisher.send(handle.snapshot())
                        Logger.resolver
                            .trace(
                                "RESOLVED - X :: failed waiting \(previousRequests) of \(self.maxRetriesForFetch) requests for  \(id) -> [UNAVAILABLE]"
                            )
                        throw Errors.DocUnavailable(id: id)
                    }
                }
            case .ready:
                guard let doc = handle.doc else { fatalError("DocHandle state is ready, but ._doc is null") }
                Logger.resolver.trace("RESOLVED! :: \(id) [\(String(describing: handle.state))]")
                return DocHandle(id: id, doc: doc)
            case .unavailable:
                Logger.resolver.trace("RESOLVED - X :: \(id) -> [MARKED UNAVAILABLE]")
                throw Errors.DocUnavailable(id: handle.id)
            case .deleted:
                Logger.resolver.trace("RESOLVED - X :: \(id) -> [MARKED DELETED]")
                throw Errors.DocDeleted(id: handle.id)
            }
        } else {
            Logger.resolver.error("RESOLVED - X :: Error Resolving document: Repo doesn't have a handle for \(id).")
            throw Errors.DocUnavailable(id: id)
        }
    }
}
