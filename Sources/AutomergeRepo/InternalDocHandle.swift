internal import struct Automerge.ChangeHash
internal import class Automerge.Document
internal import struct Automerge.SyncState
internal import struct Foundation.Data

final class InternalDocHandle {
    enum DocHandleState {
        case idle
        case loading
        case requesting
        case ready
        case unavailable
        case deleted
    }

    // NOTE: heckj - what I was originally researching how this all goes together, I
    // wondered if there wasn't the concept of unloading/reloading the bytes from memory and
    // onto disk when there was a storage system available - in that case, we'd need a few
    // more states to this diagram (originally from `automerge-repo`) - one for 'purged' and
    // an associated action PURGE - the idea being that might be invoked when an app is coming
    // under memory pressure.
    //
    // The state itself is driven from Repo, in the `resolveDocHandle(id:)` method

    /**
     * Internally we use a state machine to orchestrate document loading and/or syncing, in order to
     * avoid requesting data we already have, or surfacing intermediate values to the consumer.
     *
     *                          ┌─────────────────────┬─────────TIMEOUT────►┌─────────────┐
     *                      ┌───┴─────┐           ┌───┴────────┐            │ unavailable │
     *  ┌───────┐  ┌──FIND──┤ loading ├─REQUEST──►│ requesting ├─UPDATE──┐  └─────────────┘
     *  │ idle  ├──┤        └───┬─────┘           └────────────┘         │
     *  └───────┘  │            │                                        └─►┌────────┐
     *             │            └───────LOAD───────────────────────────────►│ ready  │
     *             └──CREATE───────────────────────────────────────────────►└────────┘
     */

    let id: DocumentId
    var doc: Automerge.Document?
    var state: DocHandleState
    // Uncomment for a trace/debugging point to see what's updating the state of a DocHandle, useful for setting
    // and capturing with a breakpoint...
//    {
//        willSet {
//            Logger.repo.trace("updating state of \(self.id) to \(String(describing: newValue))")
//        }
//    }

    /// A Boolean value that indicates the document was added to the repository by way of syncing with a remote peer,
    /// and hasn't been explicitly asked for by the app using this repository.
    var remote: Bool
    var remoteHeads: [STORAGE_ID: Set<Automerge.ChangeHash>]
    var syncStates: [PEER_ID: SyncState]

    // TODO: verify that we want a timeout delay per Document, as opposed to per-Repo
    var timeoutDelay: Double

    init(
        id: DocumentId,
        isNew: Bool,
        initialValue: Automerge.Document? = nil,
        timeoutDelay: Double = 1.0,
        remote: Bool = false
    ) {
        self.id = id
        self.timeoutDelay = timeoutDelay
        self.remote = remote
        remoteHeads = [:]
        syncStates = [:]
        // isNew is when we're creating content and it needs to get stored locally in a storage
        // provider, if available.
        if isNew {
            if let newDoc = initialValue {
                doc = newDoc
                state = .loading
            } else {
                doc = nil
                state = .idle
            }
        } else if let newDoc = initialValue {
            doc = newDoc
            state = .ready
        } else {
            doc = nil
            state = .idle
        }
    }

    var isReady: Bool {
        state == .ready
    }

    var isDeleted: Bool {
        state == .deleted
    }

    var isUnavailable: Bool {
        state == .unavailable
    }

    // not entirely sure why this is holding data about remote heads... convenience?
    // why not track within Repo?
    func getRemoteHeads(id: STORAGE_ID) async -> Set<ChangeHash>? {
        remoteHeads[id]
    }

    func setRemoteHeads(id: STORAGE_ID, heads: Set<ChangeHash>) {
        remoteHeads[id] = heads
    }

    // For testing only - snapshot of current state of a DocHandle
    struct DocHandleSnapshot {
        let docExists: Bool
        let id: DocumentId
        let state: DocHandleState
        let remote: Bool
        let remoteHeads: [STORAGE_ID: Set<Automerge.ChangeHash>]
        let syncStates: [PEER_ID: SyncState]
    }

    func snapshot() -> DocHandleSnapshot {
        DocHandleSnapshot(
            docExists: self.doc != nil,
            id: id,
            state: state,
            remote: remote,
            remoteHeads: remoteHeads,
            syncStates: syncStates
        )
    }
}
