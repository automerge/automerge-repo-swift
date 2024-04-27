# ``AutomergeRepo/PeerToPeerProvider``

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
