import Foundation
#if os(iOS)
import UIKit // for UIDevice.name access
#endif

public struct PeerToPeerProviderConfiguration: Sendable {
    let passcode: String
    let reconnectOnError: Bool
    let autoconnect: Bool

    let recurringNextMessageTimeout: ContinuousClock.Instant.Duration
    let waitForPeerTimeout: ContinuousClock.Instant.Duration

    public init(
        passcode: String,
        reconnectOnError: Bool = true,
        autoconnect: Bool? = nil,
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
    }

    // MARK: default sharing identity

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
