import Automerge
import OSLog

public enum LogComponent: String, Hashable, Sendable {
    case storage
    case network
    case repo
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
