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
    
    func logLevel(_ component: LogComponent) -> LogVerbosity {
        if let level = levels[component] {
            return level
        }
        return defaultVerbosity
    }
}
