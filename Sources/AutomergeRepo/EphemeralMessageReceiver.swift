/// A type that accepts ephemeral messages as they arrive from connected network peers.
public protocol EphemeralMessageReceiver: Sendable {
    /// Receive and process an an ephemeral message from a repository.
    /// - Parameter msg: The ephemeral message.
    ///
    /// Conform a type to this protocol to be able to accept and process ``SyncV1Msg/ephemeral(_:)``, provided by other
    /// connected peers.
    /// This message type exists in the Automerge Repo Sync protocol to allow you to send and receive app-specific
    /// messages.
    /// Decode the ``SyncV1Msg/EphemeralMsg/data`` to receive and process the message.
    func receiveMessage(_ msg: SyncV1Msg.EphemeralMsg) async
}
