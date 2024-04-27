# ``AutomergeRepo/Repo``

## Topics

### Creating a repository

- ``init(sharePolicy:saveDebounce:)-9tksd``
- ``init(sharePolicy:saveDebounce:)-8umfb``
- ``init(sharePolicy:storage:saveDebounce:)``
- ``init(sharePolicy:storage:networks:saveDebounce:)``

### Configuring a repository

- ``addNetworkAdapter(adapter:)``
- ``setDelegate(_:)``

### Creating documents

- ``create()``
- ``create(id:)``
- ``create(data:id:)``
- ``create(doc:id:)``

### Importing and exporting documents

- ``import(data:)``
- ``export(id:)``

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
