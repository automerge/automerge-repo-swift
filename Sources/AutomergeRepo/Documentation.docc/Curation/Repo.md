# ``AutomergeRepo/Repo``

## Overview

Initialize a repository with a storage provider to enable automatic loading and saving of Automerge documents to persistent storage.
Add one or more network adapters to support synchronization of updates between any connected peers.
Documents are shared on request, or not, based on ``SharePolicy`` you provide when creating the repository.

Enable network providers with async calls to ``addNetworkAdapter(adapter:)``.
When network providers are active, the repository attempts to sync documents with connected peers on any update to the an Automerge document.

## Topics

### Creating a repository

- ``init(sharePolicy:saveDebounce:)-9tksd``
- ``init(sharePolicy:saveDebounce:)-8umfb``
- ``init(sharePolicy:storage:saveDebounce:)``
- ``init(sharePolicy:storage:networks:saveDebounce:)``

### Configuring a repository

- ``addNetworkAdapter(adapter:)``
- ``setDelegate(_:)``
- ``setLogLevel(_:to:)``
- ``LogComponent``

### Creating documents

- ``create()``
- ``create(id:)``
- ``create(data:id:)``
- ``create(doc:id:)``

### Cloning a document

- ``clone(id:)``

### Requesting a document

- ``find(id:)``

### Deleting a document

- ``delete(id:)``

### Inspecting a repository

- ``storageId()``
- ``peerId``
- ``localPeerMetadata``

- ``documentIds()``
- ``peers()``

### Requesting ongoing updates from peers

- ``subscribeToRemotes(remotes:)``

### Sending app-specific messages

- ``send(_:to:)``
- ``send(count:sessionId:documentId:data:to:)``
