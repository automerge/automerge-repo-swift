# Implementation Notes to Future Me (or any Contributors)

Repo is the heart of this library. 
When you `import AutomergeRepo`, the primary purpose is to create an instance of repo to hold Automerge documents.
In addition to holding documents (its most basic functionality), Repo has 'pluggable' storage and networking capability.
Repo is meant to handle any and all coordination for persisting documents (if it has a storage module), and synchronization of documents and related data (for any networking modules).
A repo can have 0 or 1 storage plugins, and 0 to N network plugins.

All the public methods on repo are (intentially) async methods, primarily returning DocHandle, a type that encapsulates both a DocumentID and an Automerge Document.

Internal to the repository the operations are all handled using a flow of events. 
This is more apparent in the Networking Subsystem, but touches everything.
In the original (javascript) Automerge-repo, this was done with emitted events from the various javascript objects.

The original project assumed a completely passive storage system, which never generates events, and a very active network system, which does.
This project replaces most of that with async calls, although in a few places there are Combine publishers.
The events *from* a plugin are encapsulated by an Enumeration xxx, and the events to a plugin are represented by async calls.

In addition to tracking documents and their state, Repo also tracks network-connected peers and the state of any documents they're sharing.
This is what allows Repo to know when to both synchronize (and persist, if a storage provider is available) documents with peers.
Repo uses the ObservableObject aspect of Automerge documents to know when they change to trigger updates.

The Combine publishers are primarily for external consumption of events originated from within Repo or it's plugins.

## Managing Documents with a state machine

Internal to Repo, that information - and more (state detail) - is managed by an internal class InternalDocHandle.
The possible states to accomodate the storage and networking flows are all encoded into the xxx Enumeration.
Processing the state machine for documents is all done in the internal method resolveDoc() on Repo.
The end result of any call to `resolveDoc` is either a DocHandle or an exception.
As an async process, the resolveDoc method may have many suspensions and take a fair amount of time to complete.


## Plugins

Everything is set up to have a few in-repo providers, but also allow anyone to add their own storage or network modules.

### Storage Plugins/Providers

What you need to supply when you create a storage plugin is encoded in the StorageProvider protocol.
Likewise, there is a NetworkProvider protocol for Network plugin. 
Yes, I'm using plugin and provider interchangably there.

### Network Plugins/Providers

A network provider can support incoming, outgoing connections, or both, but does not have to support more than 1 connection.
The WebSocket provider, for example, only supports a single, outgoing connection.
The PeerToPeer provider supports multiple connections, both incoming and outgoing.

## WebSocket Network Provider

## PeerToPeer Network Provider