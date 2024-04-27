# ``AutomergeRepo/StorageProvider``

## Topics

### Inspecting the storage provider

- ``id``

### Loading and storing data

- ``load(id:)``
- ``save(id:data:)``

### Removing documents

- ``remove(id:)``

### Incremental document updates

- ``addToRange(id:prefix:data:)``
- ``loadRange(id:prefix:)``
- ``removeRange(id:prefix:data:)``
- ``CHUNK``
