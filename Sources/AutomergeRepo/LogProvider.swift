import Automerge
import OSLog

@AutomergeRepo
final class LogProvider {

    let defaultVerbosity: LogVerbosity = .errorOnly
    
    private var levels: [LogComponent:LogVerbosity] = [:]

    nonisolated init() { }
    
    func setLevel(_ component: LogComponent, to: LogVerbosity) {
        levels[component] = to
    }
    
    // example: LogProvider.canTrace(.repo)?.trace
    func canTrace(_ component: LogComponent) -> Logger? {
        if let level = levels[component], level >= LogVerbosity.tracing {
            return component.logger()
        }
        // nothing recorded, default to error only
        return nil
    }

    func canDebug(_ component: LogComponent) -> Logger? {
        if let level = levels[component], level >= LogVerbosity.debug {
            return component.logger()
        }
        // nothing recorded, default to error only
        return nil
    }

    func logger(for component: LogComponent) -> Logger? {
        return component.logger()
    }
}

