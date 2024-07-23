internal import Automerge
internal import OSLog

public extension Repo {
    /// Represents the primary internal components of a repository
    enum LogComponent: String, Hashable, Sendable {
        /// The storage subsystem
        case storage
        /// The network subsystem
        case network
        /// The top-level repository coordination
        case repo
        /// The document state resolution system
        case resolver

        func logger() -> Logger {
            switch self {
            case .storage:
                Logger.storage
            case .network:
                Logger.network
            case .repo:
                Logger.repo
            case .resolver:
                Logger.resolver
            }
        }
    }
}
