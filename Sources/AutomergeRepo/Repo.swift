public import Automerge
internal import AutomergeUtilities
@preconcurrency internal import Combine
public import Foundation
internal import OSLog

/// A repository for Automerge documents that coordinates storage and synchronization.
@AutomergeRepo
public final class Repo {
    /// The peer ID for the repository
    public nonisolated let peerId: PEER_ID
    /// The metadata for the repository
    public var localPeerMetadata: PeerMetadata

    private var handles: [DocumentId: InternalDocHandle] = [:]
    private var observerHandles: [DocumentId: AnyCancellable] = [:]
    private var storage: DocumentStorage?
    private var network: NetworkSubsystem

    var sharePolicy: any ShareAuthorizing

    // MARK: log filtering

    let defaultVerbosity: LogVerbosity = .errorOnly
    private var levels: [LogComponent: LogVerbosity] = [:]
    /// LogVerbosity of Documents created from the Repo
    public var documentLogVerbosity: LogVerbosity = .errorOnly {
        didSet {
            self.storage?.documentLogLevel = documentLogVerbosity
        }
    }

    // MARK: log filtering

    nonisolated let saveSignalPublisher: PassthroughSubject<DocumentId, Never> = PassthroughSubject()
    private var saveSignalHandler: AnyCancellable?
    nonisolated let saveDebounceDelay: RunLoop.SchedulerTimeType.Stride

    /** maps peer id to to persistence information (storageId, isEphemeral), access by collection synchronizer  */
    /** @hidden */
    private var peerMetadataByPeerId: [PEER_ID: PeerMetadata] = [:]

    private let maxRetriesForFetch: Int
    private let pendingRequestWaitDuration: Duration
    private var pendingRequestReadAttempts: [DocumentId: Int] = [:]

    private var remoteHeadsGossipingEnabled = false

    private var _ephemeralMessageDelegate: (any EphemeralMessageReceiver)?

    // TESTING HOOKS - for receiving state updates while testing
    nonisolated let docHandlePublisher: PassthroughSubject<InternalDocHandle.DocHandleSnapshot, Never> =
        PassthroughSubject()

    struct SyncRequest {
        let id: DocumentId
        let peer: PEER_ID
    }

    /// An internal publisher that triggers a message on sending, or receiving, a sync message (including
    /// receiving, but not initiating, a request msg).
    ///
    /// On a sent request, the peer in the `SyncRequest` is the peer we're syncing towards.
    /// On a received request, the peer in the `SyncRequest` is the peer from which we received the message.
    nonisolated let syncRequestPublisher: PassthroughSubject<SyncRequest, Never> =
        PassthroughSubject()

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
    /// - Parameter saveDebounce: The delay time to accumulate changes to a document before initiating a network sync
    /// with available peers. The default is 2 seconds.
    /// - Parameter maxResolveFetchIterations: The number of checks to make waiting for peers to provide a requested
    /// document. The default value is 300, after which the repository throws an error from ``find(id:)`` that indicates
    /// the document is unavailable.
    /// - Parameter resolveFetchIterationDelay: The delay between checks while waiting for peers to provide a requested
    /// document. The default is 1 second.
    public nonisolated init(
        sharePolicy: SharePolicy,
        saveDebounce: RunLoop.SchedulerTimeType.Stride = .seconds(10),
        maxResolveFetchIterations: Int = 300,
        resolveFetchIterationDelay: Duration = .seconds(1)
    ) {
        peerId = UUID().uuidString
        storage = nil
        maxRetriesForFetch = maxResolveFetchIterations
        pendingRequestWaitDuration = resolveFetchIterationDelay
        localPeerMetadata = PeerMetadata(storageId: nil, isEphemeral: true)
        self.sharePolicy = sharePolicy as any ShareAuthorizing
        network = NetworkSubsystem(verbosity: .errorOnly)
        saveDebounceDelay = saveDebounce
    }

    /// Create a new repository with the custom share policy type you provide
    /// - Parameter sharePolicy: A type that conforms to ``ShareAuthorizing`` to use to determine if a repository shares
    /// a document.
    /// - Parameter saveDebounce: The delay time to accumulate changes to a document before initiating a network sync
    /// with available peers. The default is 2 seconds.
    /// - Parameter maxResolveFetchIterations: The number of checks to make waiting for peers to provide a requested
    /// document. The default value is 300, after which the repository throws an error from ``find(id:)`` that indicates
    /// the document is unavailable.
    /// - Parameter resolveFetchIterationDelay: The delay between checks while waiting for peers to provide a requested
    /// document. The default is 1 second.
    public nonisolated init(
        sharePolicy: some ShareAuthorizing,
        saveDebounce: RunLoop.SchedulerTimeType.Stride = .seconds(10),
        maxResolveFetchIterations: Int = 300,
        resolveFetchIterationDelay: Duration = .seconds(1)
    ) {
        peerId = UUID().uuidString
        storage = nil
        maxRetriesForFetch = maxResolveFetchIterations
        pendingRequestWaitDuration = resolveFetchIterationDelay
        localPeerMetadata = PeerMetadata(storageId: nil, isEphemeral: true)
        self.sharePolicy = sharePolicy
        network = NetworkSubsystem(verbosity: .errorOnly)
        saveDebounceDelay = saveDebounce
    }

    /// Create a new repository with the share policy and storage provider that you provide.
    /// - Parameters:
    ///   - sharePolicy: The policy to use to determine if a repository shares a document.
    ///   - storage: The storage provider for the repository.
    ///   - saveDebounce: The delay time to accumulate changes to a document before initiating a network sync with
    /// available peers. The default is 2 seconds.
    ///   - maxResolveFetchIterations: The number of checks to make waiting for peers to provide a requested document.
    /// The default value is 300, after which the repository throws an error from ``find(id:)`` that indicates the
    /// document is unavailable.
    ///   - resolveFetchIterationDelay: The delay between checks while waiting for peers to provide a requested. The
    /// default is 1 second.
    public nonisolated init(
        sharePolicy: SharePolicy,
        storage: some StorageProvider,
        saveDebounce: RunLoop.SchedulerTimeType.Stride = .seconds(10),
        maxResolveFetchIterations: Int = 300,
        resolveFetchIterationDelay: Duration = .seconds(1)
    ) {
        peerId = UUID().uuidString
        maxRetriesForFetch = maxResolveFetchIterations
        pendingRequestWaitDuration = resolveFetchIterationDelay
        self.sharePolicy = sharePolicy as any ShareAuthorizing
        network = NetworkSubsystem(verbosity: .errorOnly)
        self.storage = DocumentStorage(storage, verbosity: .errorOnly, documentLogVerbosity: documentLogVerbosity)
        localPeerMetadata = PeerMetadata(storageId: storage.id, isEphemeral: false)
        saveDebounceDelay = saveDebounce
        Task { await self.setupSaveHandler() }
    }

    /// Create a new repository with the share policy and storage provider that you provide.
    /// - Parameters:
    ///   - sharePolicy: The policy to use to determine if a repository shares a document.
    ///   - storage: The storage provider for the repository.
    ///   - networks: A list of network providers to add.
    ///   - saveDebounce: The delay time to accumulate changes to a document before initiating a network sync with
    /// available peers. The default is 2 seconds.
    ///   - maxResolveFetchIterations: The number of checks to make waiting for peers to provide a requested document.
    /// The default value is 300, after which the repository throws an error from ``find(id:)`` that indicates the
    /// document is unavailable.
    ///   - resolveFetchIterationDelay: The delay between checks while waiting for peers to provide a requested
    /// document. The default is 1 second.
    public init(
        sharePolicy: SharePolicy,
        storage: some StorageProvider,
        networks: [any NetworkProvider],
        saveDebounce: RunLoop.SchedulerTimeType.Stride = .seconds(10),
        maxResolveFetchIterations: Int = 300,
        resolveFetchIterationDelay: Duration = .seconds(1)
    ) {
        self.sharePolicy = sharePolicy as any ShareAuthorizing
        peerId = UUID().uuidString
        maxRetriesForFetch = maxResolveFetchIterations
        pendingRequestWaitDuration = resolveFetchIterationDelay
        self.storage = DocumentStorage(storage, verbosity: .errorOnly, documentLogVerbosity: documentLogVerbosity)
        self.saveDebounceDelay = saveDebounce

        localPeerMetadata = PeerMetadata(storageId: storage.id, isEphemeral: false)
        network = NetworkSubsystem(verbosity: .errorOnly)
        self.setupSaveHandler()
        network.setRepo(self)
        for adapter in networks {
            network.addAdapter(adapter: adapter)
        }
    }

    // MARK: log filtering

    /// Update the verbosity of logging for the repository component you identify.
    /// - Parameters:
    ///   - component: The component to adjust.
    ///   - to: The logging verbosity to use.
    ///
    /// By default, all components log at `.errorOnly`, which sends errors and warnings to the unified logging system.
    public func setLogLevel(_ component: LogComponent, to: LogVerbosity) {
        levels[component] = to
        if component == .network {
            network.setLogVerbosity(to)
        }
        if let storage, component == .storage {
            storage.setLogVerbosity(to)
        }
    }

    func logLevel(_ component: LogComponent) -> LogVerbosity {
        if let level = levels[component] {
            return level
        }
        return defaultVerbosity
    }

    // MARK: log filtering

    private func setupSaveHandler() {
        saveSignalHandler = saveSignalPublisher
            .debounce(for: saveDebounceDelay, scheduler: RunLoop.main)
            .sink(receiveValue: { [weak self] id in
                guard let self,
                      let storage = self.storage,
                      let docHandle = self.handles[id],
                      let docFromHandle = docHandle.doc
                else {
                    return
                }
                Task {
                    try await storage.saveDoc(id: id, doc: docFromHandle)
                }
            })
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
    public func setDelegate(_ delegate: some EphemeralMessageReceiver) {
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
        if await sharePolicy.share(peer: peer, docId: docId) {
            if logLevel(.repo).canTrace() {
                Logger.repo.trace("REPO: \(self.peerId) starting a sync for document \(docId) to \(peer)")
            }
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
                    syncRequestPublisher.send(SyncRequest(id: docId, peer: peer))
                    await network.send(message: syncMsg, to: peer)
                }
            } catch {
                Logger.repo
                    .error(
                        "REPO: \(self.peerId) Failed to generate sync on peer connection: \(error.localizedDescription, privacy: .public)"
                    )
            }
        } else {
            if logLevel(.repo).canTrace() {
                Logger.repo.warning("REPO: \(self.peerId) SharePolicy DENIED sharing document \(docId) to \(peer)")
            }
        }
    }

    func addPeerWithMetadata(peer: PEER_ID, metadata: PeerMetadata?) async {
        assert(peer != self.peerId)
        peerMetadataByPeerId[peer] = metadata
        if logLevel(.repo).canTrace() {
            Logger.repo.trace("REPO: \(self.peerId) adding peer \(peer)")
        }
        for docId in documentIds() {
            await beginSync(docId: docId, to: peer)
        }
    }

    func removePeer(peer: PEER_ID) {
        peerMetadataByPeerId.removeValue(forKey: peer)
    }

    // MARK: Handle pass-back of Ephemeral Messages

    func handleEphemeralMessage(_ msg: SyncV1Msg.EphemeralMsg) async {
        await _ephemeralMessageDelegate?.receiveMessage(msg)
    }

    // MARK: Synchronization Pieces - Observe internal docs

    /// Creates an observer, if one doesn't already exist, to watch for `objectWillChange`
    /// notifications from the Automerge document.
    /// - Parameter id: The document Id to track with this observer
    func watchDocForChanges(id: DocumentId) {
        guard let handle = handles[id] else {
            // no such document in our set of document handles
            return
        }
        if let doc = handle.doc, handle.state == .ready, observerHandles[id] == nil {
            // sync changes should be invoked as rapidly as possible to allow for best possible
            // collaborative editing experiences.
            let handleObserver = doc.objectWillChange
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.saveSignalPublisher.send(id)
                    syncToAllPeers(id: id)
                }
            observerHandles[id] = handleObserver
        }
    }

    /// Request a sync to all connected peers.
    /// - Parameter id: The id of the document to sync.
    ///
    /// The repo only initiates a sync when the repository's ``SharePolicy/share(peer:docId:)``
    /// method allows the document to be replicated to other peers.
    func syncToAllPeers(id: DocumentId) {
        for peer in self.peerMetadataByPeerId.keys {
            Task {
                await self.beginSync(docId: id, to: peer)
            }
        }
    }

    // MARK: Synchronization Pieces - For Network Subsystem Access

    func handleSync(msg: SyncV1Msg.SyncMsg) async {
        if logLevel(.repo).canTrace() {
            Logger.repo.trace("REPO: \(self.peerId) - handling a sync msg from \(msg.senderId) to \(msg.targetId)")
        }
        guard let docId = DocumentId(msg.documentId) else {
            Logger.repo
                .warning(
                    "REPO: Invalid documentId \(msg.documentId) received in a sync message \(msg.debugDescription)"
                )
            return
        }
        if logLevel(.repo).canTrace() {
            Logger.repo.trace("REPO:  - Sync request received for document \(docId)")
        }
        do {
            if handles[docId] == nil {
                if logLevel(.repo).canTrace() {
                    Logger.repo.trace("REPO:  - No recorded handle for \(docId), creating one")
                }
                // There is no in-memory handle for the document being synced, so this is a request
                // to create a local copy of the document encapsulated in the sync message.
                let newDocument = Document(logLevel: documentLogVerbosity)
                let newHandle = InternalDocHandle(id: docId, isNew: true, initialValue: newDocument, remote: true)
                docHandlePublisher.send(newHandle.snapshot())
                // must update the repo with the new handle and empty document _before_
                // using syncState, since it needs to resolve the documentId
                handles[docId] = newHandle
                _ = try await resolveDocHandle(id: docId)
            }
            guard let handle = handles[docId] else { fatalError("HANDLE DOESN'T EXIST") }
            if handle.state == .deleted {
                // if the handle is marked as `deleted`, then the document has been removed from this
                // repository and shouldn't be updated or re-created.
                return
            }
            if logLevel(.repo).canTrace() {
                Logger.repo.trace("REPO:  - working on handle for \(docId), state: \(String(describing: handle.state))")
            }
            let docFromHandle = handle.doc ?? Document(logLevel: documentLogVerbosity)
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
                if logLevel(.repo).canTrace() {
                    Logger.repo
                        .trace("REPO: Sync received and applied, replying with a sync msg back to \(msg.senderId)")
                }
                await network.send(message: syncMsg, to: msg.senderId)
            }
            // testing hook to send an internal notification that a sync message has been received (and implies
            // that it's also been processed)
            syncRequestPublisher.send(SyncRequest(id: docId, peer: msg.senderId))
            // else no sync is needed, as the last sync state reports that it knows about
            // all the changes it needs - that it's up to date with the local document
        } catch {
            let err: SyncV1Msg =
                .error(.init(message: "Error receiving sync: \(error.localizedDescription)"))
            Logger.repo.warning("REPO: Error receiving initial sync for \(docId, privacy: .public)")
            await network.send(message: err, to: msg.senderId)
        }
    }

    func handleRequest(msg: SyncV1Msg.RequestMsg) async {
        guard let docId = DocumentId(msg.documentId) else {
            Logger.repo
                .warning(
                    "REPO: Invalid documentId \(msg.documentId) received in a sync message \(msg.debugDescription)"
                )
            return
        }
        if let internalHandle = handles[docId], internalHandle.state != .deleted {
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
                    syncRequestPublisher.send(SyncRequest(id: docId, peer: msg.senderId))
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
    ///
    /// The repo only initiates a sync to connected peers when the repository's
    ///  ``SharePolicy/share(peer:docId:)`` method allows the document to be replicated the peer.
    public func create() async throws -> DocHandle {
        let handle = InternalDocHandle(id: DocumentId(), isNew: true, initialValue: Document(logLevel: documentLogVerbosity))
        handles[handle.id] = handle
        docHandlePublisher.send(handle.snapshot())
        let resolved = try await resolveDocHandle(id: handle.id)
        syncToAllPeers(id: handle.id)
        return resolved
    }

    /// Creates a new Automerge document, storing it and sharing the creation with connected peers.
    /// - Returns: The Automerge document.
    /// - Parameter id: The Id of the Automerge document.
    ///
    /// The repo only initiates a sync to connected peers when the repository's
    ///  ``SharePolicy/share(peer:docId:)`` method allows the document to be replicated the peer.
    public func create(id: DocumentId) async throws -> DocHandle {
        if let _ = handles[id] {
            throw Errors.DuplicateID(id: id)
        }
        let handle = InternalDocHandle(id: id, isNew: true, initialValue: Document(logLevel: documentLogVerbosity))
        handles[handle.id] = handle
        docHandlePublisher.send(handle.snapshot())
        let resolved = try await resolveDocHandle(id: handle.id)
        syncToAllPeers(id: handle.id)
        return resolved
    }

    /// Imports an Automerge document with an option Id, and potentially share it with connected peers.
    /// - Parameter handle: The handle to the Automerge document to import.
    /// - Returns: A handle to the Automerge document.
    ///
    /// If the ID you provide in the handle already exists in the local repository,
    /// the import attempts to merge the document you provide with an existing document.
    /// This process does not request the document from any connected network peers.
    /// To request a document by Id from network peers, use ``find(id:)``.
    ///
    /// To import the raw bytes of an Automerge document, load it into an Automerge document
    /// and create a new, random DocumentId:
    ///
    /// ```swift
    /// let documentFromData = try Document(data)
    /// let newHandle = DocHandle(id: DocumentId(), doc: documentFromData)
    /// ```
    ///
    /// Use the handle you create with `import(handle:)` to load it into the repository.
    ///
    /// The repo only initiates a sync to connected peers when the repository's
    ///  ``SharePolicy/share(peer:docId:)`` method allows the document to be replicated the peer.
    @discardableResult
    public func `import`(handle: DocHandle) async throws -> DocHandle {
        if let existingHandle = handles[handle.id] {
            if [.loading, .requesting].contains(existingHandle.state) {
                // The state of the internal handle is in .requesting or .loading, meaning those
                // processes are in place, or were in place and aborted. To resolve any potential
                // concurrency issues, we'll resolve to a known state that we can handle and continue
                // with merging from there.
                do {
                    let _ = try await resolveDocHandle(id: existingHandle.id)
                } catch {
                    // intentionally catch errors to indicate that the state is resolved
                    // so that we can continue
                }
            }
            // verify that the document exists on the handle, and if so, merge
            // and save it
            if let existingDoc = existingHandle.doc {
                try existingDoc.merge(other: handle.doc)
                // store the document if there's a storage provider available
                try await storage?.saveDoc(id: existingHandle.id, doc: existingDoc)
            } else {
                // if there isn't a document on the internal handle, use the document
                // provided.
                existingHandle.doc = handle.doc
                // store the document if there's a storage provider available
                try await storage?.saveDoc(id: existingHandle.id, doc: handle.doc)
            }
            existingHandle.state = .ready
            docHandlePublisher.send(existingHandle.snapshot())
            // calling resolveDocHandle when we've just set the state to .ready
            // is tantamount to asking for a DocHandle from the internal variation
            // but with some extra checks to make sure nothing is awry with expected state.
            let handle = try await resolveDocHandle(id: existingHandle.id)
            syncToAllPeers(id: handle.id)
            return handle
        } else {
            // Id from the handle provided does not yet exist within the repository
            // establish a new internal doc handle
            let internalHandle = InternalDocHandle(id: handle.id, isNew: true, initialValue: handle.doc)
            // preset it to the state of ready and add it to the repositories collection of handles
            internalHandle.state = .ready
            handles[handle.id] = internalHandle
            // explicitly save to persistent storage, if available, before returning
            try await storage?.saveDoc(id: handle.id, doc: handle.doc)
            docHandlePublisher.send(internalHandle.snapshot())
            let handle = try await resolveDocHandle(id: handle.id)
            syncToAllPeers(id: handle.id)
            return handle
        }
    }

    /// Clones a document the repo already knows to create a new, shared document.
    /// - Parameter id: The id of the document to clone.
    /// - Returns: A handle to the Automerge document.
    ///
    /// The Repo treats the cloned document as a newly imported or created document and attempts to
    /// automatically sync to connected peers when the repository's
    ///  ``SharePolicy/share(peer:docId:)`` method allows the document to be replicated the peer.
    public func clone(id: DocumentId) async throws -> DocHandle {
        let handle = try await resolveDocHandle(id: id)
        let fork = handle.doc.fork()
        let newId = DocumentId()
        let newHandle = InternalDocHandle(id: newId, isNew: false, initialValue: fork)
        handles[newHandle.id] = newHandle
        docHandlePublisher.send(newHandle.snapshot())
        let resolved = try await resolveDocHandle(id: newHandle.id)
        syncToAllPeers(id: resolved.id)
        return resolved
    }

    /// Requests a document from any connected peers.
    /// - Parameter id: The id of the document to retrieve.
    /// - Returns: A handle to the Automerge document or throws an error if the document is unavailable.
    public func find(id: DocumentId) async throws -> DocHandle {
        // generally of the idea that we'll drive DocHandle state updates from within Repo
        // and these async methods
        let handle: InternalDocHandle
        if let knownHandle = handles[id] {
            handle = knownHandle
            // make handle as local to indicate it is already known in memory and wasn't created externally
            handle.remote = false
            docHandlePublisher.send(handle.snapshot())
        } else {
            // mark handle as remote to indicate we don't have this locally
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
        // cancel observing for changes
        if let observerHandle = observerHandles[id] {
            observerHandle.cancel()
            observerHandles.removeValue(forKey: id)
        }
        docHandlePublisher.send(originalDocHandle.snapshot())

        try await self.purgeFromStorage(id: id)
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

    /// Sends an app-specific data encoded into an ephemeral message to peers on your network.
    /// - Parameters:
    ///   - msg: The ephemeral message to send.
    ///   - peer: The peer to send the message to, or nil to broadcast to all connected peers.
    public func send(_ msg: SyncV1Msg.EphemeralMsg, to peer: PEER_ID? = nil) async {
        await network.send(message: .ephemeral(msg), to: peer)
    }

    /// Sends an app-specific data encoded into an ephemeral message to peers on your network.
    /// - Parameters:
    ///   - count: A count.
    ///   - sessionId: A session Id.
    ///   - documentId: The documentId associated with the message.
    ///   - data: The app-specific data.
    ///   - peer: The peer send the message to, or nil to broadcast to all connected peers.
    public func send(
        count: UInt,
        sessionId: String,
        documentId: DocumentId,
        data: Data,
        to peer: PEER_ID? = nil
    ) async {
        let msg: SyncV1Msg = .ephemeral(.init(
            senderId: self.peerId,
            targetId: peer ?? self.peerId,
            count: count,
            sessionId: sessionId,
            documentId: documentId.id,
            data: data
        ))
        await network.send(message: msg, to: peer)
    }
    
    public func savePendingChanges(id: DocumentId) async throws {
        guard let storage = self.storage,
              let docHandle = self.handles[id],
              let docFromHandle = docHandle.doc
        else {
            return
        }
        
        try await storage.saveDoc(id: id, doc: docFromHandle)
    }

    // MARK: Methods to expose retrieving DocHandles to the subsystems

    func syncState(id: DocumentId, peer: PEER_ID) -> SyncState {
        guard let handle = handles[id] else {
            fatalError("No stored dochandle for id: \(id)")
        }
        if let handleSyncState = handle.syncStates[peer] {
            if logLevel(.repo).canTrace() {
                Logger.repo.trace("REPO: Providing stored sync state for doc \(id)")
            }
            return handleSyncState
        } else {
            // TODO: add attempt to load from storage and return it before creating a new one
            if logLevel(.repo).canTrace() {
                Logger.repo.trace("REPO: No stored sync state for doc \(id) and peer \(peer).")
                Logger.repo.trace("REPO: Creating a new sync state for doc \(id)")
            }
            return SyncState()
        }
    }

    func updateSyncState(id: DocumentId, peer: PEER_ID, syncState: SyncState) async {
        guard let handle = handles[id] else {
            fatalError("No stored dochandle for id: \(id)")
        }
        if logLevel(.repo).canTrace() {
            Logger.repo.trace("REPO: Storing updated sync state for doc \(id) and peer \(peer).")
        }
        handle.syncStates[peer] = syncState
    }

    func markDocUnavailable(id: DocumentId) async {
        // handling a requested document being marked as unavailable after all peers have been checked
        guard let handle = handles[id] else {
            Logger.repo.error("REPO: missing handle for documentId \(id.description) while attempt to mark unavailable")
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
        if logLevel(.repo).canTrace() {
            Logger.repo.trace("REPO: Updated contents of document \(id), state: \(String(describing: handle.state))")
        }
        // Automerge-repo https://github.com/automerge/automerge-repo/issues/343 is sending two responses,
        // the first being UNAVAILABLE, which we use to change the state, but that triggers this unexpected
        // assertion, we we later receive the SYNC update to set the document as expected
        assert(handle.state == .ready || handle.state == .unavailable || handle.state == .requesting)
        handle.doc = doc
        handle.state = .ready
        docHandlePublisher.send(handle.snapshot())
        if let storage {
            do {
                try await storage.saveDoc(id: id, doc: doc)
            } catch {
                Logger.repo
                    .warning(
                        "REPO: Error received while attempting to store document ID \(id): \(error.localizedDescription)"
                    )
            }
        }
    }

    // MARK: Methods to resolve docHandles

    func merge(id: DocumentId, with: DocumentId) async throws {
        guard let handle1 = handles[id] else {
            throw Errors.Unavailable(id: id)
        }
        guard let handle2 = handles[with] else {
            throw Errors.Unavailable(id: with)
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
        let loglevel = self.logLevel(.resolver)
        if let handle: InternalDocHandle = handles[id] {
            if loglevel.canTrace() {
                Logger.resolver.trace("RESOLVE: document id \(id) [\(String(describing: handle.state))]")
            }
            switch handle.state {
            case .idle:
                if handle.doc != nil {
                    // if there's an Automerge document in memory, jump to ready
                    handle.state = .ready
                    if loglevel.canTrace() {
                        Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                    }
                } else {
                    // otherwise, first attempt to load it from persistent storage
                    // (if available)
                    handle.state = .loading
                    if loglevel.canTrace() {
                        Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                    }
                }
                if loglevel.canTrace() {
                    Logger.resolver.trace("RESOLVE: :: continuing to resolve")
                }
                docHandlePublisher.send(handle.snapshot())
                return try await resolveDocHandle(id: id)
            case .loading:
                // Do we have the document
                if let docFromHandle = handle.doc {
                    if loglevel.canTrace() {
                        Logger.resolver.trace("RESOLVE: :: \(id) has a document in memory")
                    }
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
                    if loglevel.canTrace() {
                        Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                    }
                    docHandlePublisher.send(handle.snapshot())
                    if loglevel.canTrace() {
                        Logger.resolver.trace("RESOLVE: :: continuing to resolve")
                    }
                    return try await resolveDocHandle(id: id)
                } else {
                    // We don't have the underlying Automerge document, so attempt
                    // to load it from storage, and failing that - if the storage provider
                    // doesn't exist, for example - jump forward to attempting to fetch
                    // it from a peer.
                    if let doc = try await loadFromStorage(id: id) {
                        handle.doc = doc
                        handle.state = .ready
                        if loglevel.canTrace() {
                            Logger.resolver.trace("RESOLVE: :: loaded \(id) from storage provider")
                            Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                        }
                        if loglevel.canTrace() {
                            Logger.resolver.trace("RESOLVE: :: continuing to resolve")
                        }
                        docHandlePublisher.send(handle.snapshot())
                        return try await resolveDocHandle(id: id)
                    } else {
                        handle.state = .requesting
                        pendingRequestReadAttempts[id] = 0
                        if loglevel.canTrace() {
                            Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                            Logger.resolver.trace("RESOLVE: :: starting remote fetch")
                        }
                        try await network.startRemoteFetch(id: handle.id)
                        if loglevel.canTrace() {
                            Logger.resolver.trace("RESOLVE: :: continuing to resolve")
                        }
                        docHandlePublisher.send(handle.snapshot())
                        return try await resolveDocHandle(id: id)
                    }
                }
            case .requesting:
                guard let updatedHandle = handles[id] else {
                    Logger.resolver.error("RESOLVE: :: Missing \(id) -> [UNAVAILABLE]")
                    throw Errors.Unavailable(id: handle.id)
                }
                if updatedHandle.doc != nil, updatedHandle.state == .ready {
                    // this may not be needed... but i'm being paranoid about when the change happens
                    // due to re-entrancy and all the awaits in this method
                    return try await resolveDocHandle(id: id)
                } else {
                    guard let previousRequests = pendingRequestReadAttempts[id] else {
                        Logger.resolver
                            .error("RESOLVE: :: Missing \(id) from pending request read attempts -> [UNAVAILABLE]")
                        throw Errors.Unavailable(id: id)
                    }
                    if previousRequests < maxRetriesForFetch {
                        // we are racing against the receipt of a network result
                        // to see what we get at the end
                        if loglevel.canTrace() {
                            Logger.resolver.trace("RESOLVE: :: \(id) -> [\(String(describing: handle.state))]")
                            Logger.resolver
                                .trace(
                                    "RESOLVE: :: check # \(previousRequests) (of \(self.maxRetriesForFetch), waiting \(self.pendingRequestWaitDuration) seconds for remote fetch"
                                )
                        }
                        try await Task.sleep(for: pendingRequestWaitDuration)
                        pendingRequestReadAttempts[id] = previousRequests + 1
                        if loglevel.canTrace() {
                            Logger.resolver.trace("RESOLVE: :: continuing to resolve")
                        }
                        return try await resolveDocHandle(id: id)
                    } else {
                        updatedHandle.state = .unavailable
                        docHandlePublisher.send(handle.snapshot())
                        Logger.resolver
                            .error(
                                "RESOLVE: :: failed waiting \(previousRequests) of \(self.maxRetriesForFetch) requests for  \(id) -> [UNAVAILABLE]"
                            )
                        throw Errors.Unavailable(id: id)
                    }
                }
            case .ready:
                guard let doc = handle.doc else { fatalError("DocHandle state is ready, but ._doc is null") }
                if loglevel.canTrace() {
                    Logger.resolver.trace("RESOLVE :: \(id) [\(String(describing: handle.state))]")
                }
                watchDocForChanges(id: id)
                return DocHandle(id: id, doc: doc)
            case .unavailable:
                Logger.resolver.error("RESOLVE: :: \(id) -> [MARKED UNAVAILABLE]")
                throw Errors.Unavailable(id: handle.id)
            case .deleted:
                Logger.resolver.error("RESOLVE: :: \(id) -> [MARKED DELETED]")
                throw Errors.DocDeleted(id: handle.id)
            }
        } else {
            Logger.resolver.error("RESOLVE: :: Error Resolving document: Repo doesn't have a handle for \(id).")
            throw Errors.Unavailable(id: id)
        }
    }
}
