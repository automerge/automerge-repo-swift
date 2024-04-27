# ``AutomergeRepo``

Manage and share a collection of Automerge documents.

## Overview

Automerge Repo provides a coordinator that tracks Automerge documents using a well-defined Document ID.
Without any of the storage or network providers enabled, the repository acts as a collection location for Automerge documents, storing, and accessing them, by a unique Document ID.
The library has a plugin architecture, so in addition to the storage and network providers offered in this library, you can create your own providers to support custom network transports or persistent storage needs.

With an optional storage provider, the repository manages saving documents to persistent filesystems.
When you use Automerge Repo with a Document-based app, you can use the repository without a storage adapter and let Apple's frameworks manage the saving and loading process to disk.
The filesystem support allows for concurrent updates to a single location by multiple applications without loosing or overwriting changes. 
For example, when your app uses a shared location in iCloud drive or DropBox.

With a network provider, you can connect to servers or other applications on a peer-to-peer network to share documents and synchronize them as changes are made by any collaborators.
Automerge Repo supports multiple active providers, allowing you to both synchronize to a server and to collaborators on a local network.
This library provides a WebSocket network provider for connecting to instances of a server app built using [automerge-repo](https://github.com/automerge/automerge-repo).
This library also provides the types, encoding, and messages to interoperate with the cross-language and cross-platform Automerge sync protocol over any network transport.

In addition to the WebSocket provider, the library offers a peer-to-peer network provider that both accepts and creates connections to other apps also supporting the peer to peer protocol.
The protocol it uses is the same sync protocol as the WebSocket, using a shared-private-key TLS encrypted socket connection with other local apps.
The peer-to-peer provider uses of Apple's Bonjour technology to connect to other local apps with a shared passcode. 

## Topics

### Managing a collection of Automerge documents

- ``AutomergeRepo/Repo``
- ``AutomergeRepo/DocHandle``
- ``AutomergeRepo/DocumentId``
- ``AutomergeRepo/EphemeralMessageReceiver``
- ``AutomergeRepo/AutomergeRepo``
- ``AutomergeRepo/Errors``

### WebSocket Network Adapter

- ``AutomergeRepo/WebSocketProvider``

### Peer to Peer Network Adapter

- ``AutomergeRepo/PeerToPeerProvider``
- ``AutomergeRepo/PeerToPeerProviderConfiguration``
- ``AutomergeRepo/PeerConnectionInfo``

### Network Adapters

- ``AutomergeRepo/NetworkProvider``
- ``AutomergeRepo/NetworkEventReceiver``
- ``AutomergeRepo/NetworkAdapterEvents``
- ``AutomergeRepo/AvailablePeer``

### Automerge-Repo Sync Protocol

- ``AutomergeRepo/SyncV1Msg``
- ``PeerMetadata``
- ``AutomergeRepo/MSG_DOCUMENT_ID``
- ``AutomergeRepo/PEER_ID``
- ``AutomergeRepo/STORAGE_ID``
- ``AutomergeRepo/SYNC_MESSAGE``

### Share Policy

- ``AutomergeRepo/SharePolicy``
- ``AutomergeRepo/ShareAuthorizing``

### Storage Adapters

- ``AutomergeRepo/StorageProvider``
- ``AutomergeRepo/CHUNK``

