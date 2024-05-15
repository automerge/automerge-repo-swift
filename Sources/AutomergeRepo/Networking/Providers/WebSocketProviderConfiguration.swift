import Automerge

/// The configuration options for a WebSocket network provider.
public struct WebSocketProviderConfiguration: Sendable {
    /// A Boolean value that indicates if the provider should attempt to reconnect when it fails with an error.
    public let reconnectOnError: Bool
    /// The verbosity of the logs sent to the unified logging system.
    public let logLevel: LogVerbosity
    /// The default configuration for the WebSocket network provider.
    ///
    /// In the default configuration:
    ///
    /// - `reconnectOnError` is `true`
    public static let `default` = WebSocketProviderConfiguration(reconnectOnError: true)

    /// Creates a new WebSocket network provider configuration instance.
    /// - Parameter reconnectOnError: A Boolean value that indicates if the provider should attempt to reconnect
    /// when it fails with an error.
    /// - Parameter loggingAt: The verbosity of the logs sent to the unified logging system.
    public init(reconnectOnError: Bool, loggingAt: LogVerbosity = .errorOnly) {
        self.reconnectOnError = reconnectOnError
        self.logLevel = loggingAt
    }
}
