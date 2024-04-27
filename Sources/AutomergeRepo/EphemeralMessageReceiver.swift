/// A type that accepts ephemeral messages as they arrive from connected network peers.
public protocol EphemeralMessageReceiver: Sendable {
    /// Receive and process an event from a Network Provider.
    /// - Parameter event: The event to process.
    func receiveEphemeralMessage(_ msg: SyncV1Msg.EphemeralMsg) async
}
