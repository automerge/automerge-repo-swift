# ``AutomergeRepo/PeerToPeerProvider``

## Overview

Create and retain a reference to an instance of `PeerToPeerProvider` to support multiple connections to other apps on your local network.

After creating the network provider, add it to ``Repo`` using ``Repo/addNetworkAdapter(adapter:)``.
For example, the [MeetingNotes demo application](https://github.com/automerge/MeetingNotes/) creates a single global instance and adds it to a repository in a Task that is invoked immediately after the app initializes:


```swift
let repo = Repo(sharePolicy: SharePolicy.agreeable)
public let repo = Repo(sharePolicy: SharePolicy.agreeable)
public let peerToPeer = PeerToPeerProvider(
    PeerToPeerProviderConfiguration(
        passcode: "AutomergeMeetingNotes",
        reconnectOnError: true,
        autoconnect: false  
    )
)

@main
struct MeetingNotesApp: App {
    ...

    init() {
        Task {
            // Enable network adapters
            await repo.addNetworkAdapter(adapter: peerToPeer)
        }
    }
}
```

Use ``startListening(as:)`` to activate the peer to peer network provider.
When active, ``availablePeerPublisher`` publishes updates from the Bonjour browser that shows all peers on the local network, including yourself. 
Filter the instances of ``AvailablePeer`` provided by the published by ``AvailablePeer/peerId`` to exclude yourself.
If the provider is not set to auto-connect, you can explicitly connect to a peer's endpoint provided in  ``AvailablePeer/endpoint``.
The ``connectionPublisher`` publishes a list of ``PeerConnectionInfo`` to provide information about active connections.
Two additional publishers, ``browserStatePublisher`` and ``listenerStatePublisher`` share status information about the Bonjour browser and listener.

## Topics

### Creating a peer-to-peer network provider

- ``init(_:)``
- ``PeerToPeerProviderConfiguration``

### Configuring the provider

- ``setDelegate(_:as:with:)``
- ``startListening(as:)``
- ``stopListening()``
- ``setName(_:)``

### Establishing Connections

- ``connect(to:)``
- ``disconnect()``
- ``disconnect(peerId:)``
- ``NetworkConnectionEndpoint``

### Sending messages

- ``send(message:to:)``

### Inspecting the provider

- ``name``
- ``peerName``
- ``peeredConnections``

### Receiving ongoing and updated information

- ``availablePeerPublisher``
- ``browserStatePublisher``
- ``listenerStatePublisher``
- ``connectionPublisher``
