/// The state of a WebSocket connection
public enum WebSocketProviderState: Sendable {
    /// WebSocket is connected, pending handshaking
    case connected
    /// WebSocket is ready to send and receive messages
    case ready
    /// WebSocket is disconnected and attempting to reconnect
    case reconnecting
    /// WebSocket is disconnected
    case disconnected
}
