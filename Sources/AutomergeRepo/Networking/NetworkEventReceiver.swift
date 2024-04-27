/// A type that accepts provides a method for a Network Provider to call with network events.
///
/// Mostly commonly, this is a ``Repo`` instance, and describes the interface that a network provider
/// uses for its delegate callbacks.
@AutomergeRepo
public protocol NetworkEventReceiver: Sendable {
    /// Receive and process an event from a Network Provider.
    /// - Parameter event: The event to process.
    func receiveEvent(event: NetworkAdapterEvents) async
}
