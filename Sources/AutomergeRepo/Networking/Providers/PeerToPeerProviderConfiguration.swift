import Foundation
#if os(iOS)
import UIKit // for UIDevice.name access
#endif

public struct PeerToPeerProviderConfiguration: Sendable {
    let passcode: String
    let listening: Bool
    let reconnectOnError: Bool
    let autoconnect: Bool

    public init(
        passcode: String,
        listening: Bool,
        reconnectOnError: Bool = true,
        autoconnect: Bool? = nil
    ) {
        self.reconnectOnError = reconnectOnError
        self.listening = listening
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
        return UserDefaults.standard
            .string(forKey: UserDefaultKeys.publicPeerName) ?? defaultName
    }
}
