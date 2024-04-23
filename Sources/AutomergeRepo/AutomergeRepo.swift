/// A global actor for coordinating data-race safety within Automerge-repo and its plugins.
///
/// ``NetworkProvider`` uses this global actor to provide an isolation zone that you can conform
/// to with your own types to provide additional network transports for Automerge-repo.

@globalActor public actor AutomergeRepo {
    /// A shared instance of the AutomergeRepo global actor
    public static let shared = AutomergeRepo()

    private init() {}
}
