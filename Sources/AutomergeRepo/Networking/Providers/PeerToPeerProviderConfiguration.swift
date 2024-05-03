import Foundation
import Automerge
#if os(iOS)
import UIKit // for UIDevice.name access
#endif

/// A type that represents a configuration for a Peer to Peer Network Provider
public struct PeerToPeerProviderConfiguration: Sendable {
    let passcode: String
    let reconnectOnError: Bool
    let autoconnect: Bool

    let recurringNextMessageTimeout: ContinuousClock.Instant.Duration
    let waitForPeerTimeout: ContinuousClock.Instant.Duration

    let logLevel: LogVerbosity
    /// Creates a new Peer to Peer Network Provider configuration
    /// - Parameters:
    ///   - passcode: A passcode to use as a shared private key to enable TLS encryption
    ///   - reconnectOnError: A Boolean value that indicates if outgoing connections should attempt to reconnect on
    /// error or failure.
    ///   - autoconnect: A Boolean value that indicates if the provider should attempt to automatically establish an
    /// outgoing connection with an available peer that it sees.
    ///   - recurringNextMessageTimeout: The timeout to wait for an additional Automerge sync protocol message.
    ///   - waitForPeerTimeout: The timeout to wait for a peer to respond to a peer request for authorizing the
    /// connection.
    public init(
        passcode: String,
        reconnectOnError: Bool = true,
        autoconnect: Bool? = nil,
        logVerbosity: LogVerbosity = .errorOnly,
        recurringNextMessageTimeout: ContinuousClock.Instant.Duration = .seconds(30),
        waitForPeerTimeout: ContinuousClock.Instant.Duration = .seconds(5)
    ) {
        self.reconnectOnError = reconnectOnError
        if let auto = autoconnect {
            self.autoconnect = auto
        } else {
            #if os(iOS)
            self.autoconnect = true
            #elseif os(macOS)
            self.autoconnect = false
            #endif
        }
        self.passcode = passcode
        self.waitForPeerTimeout = waitForPeerTimeout
        self.recurringNextMessageTimeout = recurringNextMessageTimeout
        self.logLevel = logVerbosity
    }

    // MARK: default sharing identity

    /// Returns a default peer to peer sharing identity to broadcast as your human-readable peer name.
    public static func defaultSharingIdentity() async -> String {
        let defaultName: String
        #if os(iOS)
        defaultName = await MainActor.run(body: {
            UIDevice().name
        })
        #elseif os(macOS)
        defaultName = Host.current().localizedName ?? "Automerge User"
        #endif
        return defaultName
    }
}
