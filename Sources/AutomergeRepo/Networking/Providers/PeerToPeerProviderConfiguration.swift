import Foundation
#if os(iOS)
import UIKit // for UIDevice.name access
#endif

public struct PeerToPeerProviderConfiguration: Sendable {
    let reconnectOnError: Bool
    let listening: Bool
    let autoconnect: Bool
    let peerName: String
    let passcode: String

    init(reconnectOnError: Bool, listening: Bool, peerName: String?, passcode: String, autoconnect: Bool? = nil) {
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
        if let name = peerName {
            self.peerName = name
        } else {
            self.peerName = Self.defaultSharingIdentity()
        }
        self.passcode = passcode
    }

    // MARK: default sharing identity

    public static func defaultSharingIdentity() -> String {
        let defaultName: String
        #if os(iOS)
        defaultName = UIDevice().name
        #elseif os(macOS)
        defaultName = Host.current().localizedName ?? "Automerge User"
        #endif
        return UserDefaults.standard
            .string(forKey: UserDefaultKeys.publicPeerName) ?? defaultName
    }
}
