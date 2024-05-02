import Automerge
import OSLog

public enum LogComponent: String, Hashable, Sendable {
    case network
    case repo
    case resolver
    case storage
    case coder
    case websocket
    case peer2peer
    case peerconnection

    /// Using your bundle identifier is a great way to ensure a unique identifier.
    private static let subsystem = Bundle.main.bundleIdentifier!

    /// Logs updates and interaction related to watching for external peer systems.
    private static let _peer2peer = Logger(subsystem: subsystem, category: "SyncController")

    /// Logs updates and interaction related to the process of synchronization over the network.
    private static let _peerconnection = Logger(subsystem: subsystem, category: "SyncConnection")

    /// Logs updates and interations performed by the sync protocol encoder and decoder.
    private static let _coder = Logger(subsystem: subsystem, category: "SyncCoderDecoder")

    /// Logs updates and interaction related to the process of synchronization over the network.
    private static let _websocket = Logger(subsystem: subsystem, category: "WebSocket")

    /// Logs updates and interaction related to the process of synchronization over the network.
    private static let _storage = Logger(subsystem: subsystem, category: "storageSubsystem")

    /// Repo logging
    private static let _repo = Logger(subsystem: subsystem, category: "automerge-repo")

    /// Logs updates related to tracing the resolution of docIDs within a repo
    private static let _resolver = Logger(subsystem: subsystem, category: "resolver")
    
    /// Network subsystem logging
    private static let _network = Logger(subsystem: subsystem, category: "networkSubsystem")

    func logger() -> Logger {
        switch self {
        case .network:
            return Self._network
        case .repo:
            return Self._repo
        case .resolver:
            return Self._resolver
        case .storage:
            return Self._storage
        case .coder:
            return Self._coder
        case .websocket:
            return Self._websocket
        case .peer2peer:
            return Self._peer2peer
        case .peerconnection:
            return Self._peerconnection
        }
    }
}
