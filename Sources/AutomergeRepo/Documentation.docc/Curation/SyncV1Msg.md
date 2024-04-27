# ``AutomergeRepo/SyncV1Msg``

## Topics

### Connection and handshaking messages

- ``peer(_:)``
- ``PeerMsg``

- ``join(_:)``
- ``JoinMsg``

- ``leave(_:)``
- ``LeaveMsg``

### Requesting and synchronizing documents

- ``sync(_:)``
- ``SyncMsg``

- ``request(_:)``
- ``RequestMsg``

- ``unavailable(_:)``
- ``UnavailableMsg``

### App-specific ephemeral messages

- ``ephemeral(_:)``
- ``EphemeralMsg``

### Error and unknown messages

- ``error(_:)``
- ``ErrorMsg``
- ``Errors``
- ``unknown(_:)``

### Peer information gossip messages

- ``remoteHeadsChanged(_:)``
- ``RemoteHeadsChangedMsg``

- ``remoteSubscriptionChange(_:)``
- ``RemoteSubscriptionChangeMsg``

### Updating ephemeral and gossip messages

- ``setTarget(_:)``

### Decoding Messages

- ``decode(_:)``
- ``decodePeer(_:)``

### Encoding Messages

- ``encode(_:)``

### Types of V1 Sync Messages

- ``MsgTypes``
