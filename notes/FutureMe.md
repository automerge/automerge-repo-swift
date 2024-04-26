# Implementation Notes to Future Me (or any Contributors)

Repo is the heart of this library.
When you `import AutomergeRepo`, the primary purpose is to create an instance of repo to hold Automerge documents.
In addition to holding documents (its most basic functionality), Repo has 'pluggable' storage and networking capability.
Repo is meant to handle any and all coordination for persisting documents (if it has a storage module), and synchronization of documents and related data (for any networking modules).
A repo can have 0 or 1 storage plugins, and 0 to N network plugins.
Storage providers are initialized _with_ the repo, while network providers can be initialized and added later.
There's no externalized concept of removing a network provider once added.

All the public methods on repo are (intentionally) async methods, mostly returning DocHandle, a type that encapsulates both a DocumentID and an Automerge Document.

## Responsibilities

Internal to the repository the flow operations are all handled using a flow of events, and the repository is responsible for the following:
- When the persist a document, if a storage provider is enabled.
- When a document should be synchronized.
- Coordinating information about, to, and from peers from any active network connections.

In addition to tracking documents and their state, Repo also tracks network-connected peers and the state of any documents they're sharing.
This is what allows Repo to know when to both synchronize (and persist, if a storage provider is available) documents with peers.
Repo uses the ObservableObject aspect of Automerge documents to know when they change to trigger updates.

Policy to share, or not to share, a document is controlled by a [SharePolicy](https://swiftpackageindex.com/automerge/automerge-repo-swift/documentation/automergerepo/sharepolicy), or a type that the user provides that conforms to [ShareAuthorizing](https://swiftpackageindex.com/automerge/automerge-repo-swift/documentation/automergerepo/shareauthorizing).
The information provided to the share policy is the document ID and the peer identity.

The policy of when and how to persist documents, if a storage provider exists, is hard coded in the DocHandle resolver.

## Event flow

The event-based nature of data flow is more apparent in the networking subsystem, but touches everything.
The original project assumed a completely passive storage system, which never generates events, and an active network system, which does.
Most of the event flow related to networking happens using async methods that pass an instance of the enumeration NetworkAdapterEvents.
Since the Repo can host multiple network adapters, all data from the adapters first flows through, and is managed by, the class NetworkSubsytem.
NetworkSubsystem conforms to NetworkEventReceiver, which defines the async call receiveEvent.

## Event streams and callbacks from the Repo and related providers

The Automerge sync protocol includes the concept of an [ephemeral message](https://swiftpackageindex.com/automerge/automerge-repo-swift/documentation/automergerepo/syncv1msg/ephemeralmsg).
Ephemeral message acts as a app-specific data holder that the app can use as it sees fit.
Since the repository doesn't know about how to do anything with that message, ephemeral messages are only provided when a delegate is identified for Repository that conforms to [EphemeralMessageDelegate](https://swiftpackageindex.com/automerge/automerge-repo-swift/documentation/automergerepo/ephemeralmessagedelegate).
The data flow is only expected to be consumed by a single point, and is exposed with an async API.

To expose data streams from network providers to public API consumers, the network providers incorporate Combine publishers.

## Managing Documents with a state machine

Internal to Repo, that information and more (state detail) is managed by an internal class InternalDocHandle.
Processing the state machine for documents is all done in the internal method `resolveDocHandle() async` on Repo.
The end result of any call to `resolveDocHandle` is either a DocHandle or an exception.
As an async process, the resolveDoc method may have many suspensions and take a fair amount of time to complete.

## Plugins

Everything is set up to have a few in-repo providers, but also allow anyone to add their own storage or network modules.
In addition to publicly accessible providers, there are a few providers in the Test target to allow functional testing of the repo dataflow:
- an in-memory storage provider
- an in-memory network and network provider
- a mock network provider (currently unused, as I ended up using the in-memory setup for fuller testing)

What you need to supply when you create a storage provider is encoded in the [StorageProvider](https://swiftpackageindex.com/automerge/automerge-repo-swift/documentation/automergerepo/storageprovider) protocol.
Likewise, there is a [NetworkProvider](https://swiftpackageindex.com/automerge/automerge-repo-swift/documentation/automergerepo/networkprovider) protocol for network providers.

### Storage Providers

The internal class `DocumentStorage` is responsible for choosing what methods on the StorageProvider to use. The two primary choices are to stashing temporary changes or to compact and update the document.
This bifurcated strategy allows the DocumentStorage class to use a shared persistence layer while managing multiple documents being update - some perhaps outside its control - at once.
This specifically enables using S3 or cloud storage (DropBox, iCloud, etc) as a storage provider - and to share that storage system with other processes making concurrent updates.

In the upstream automerge-repo project, storage providers were only passive actors, but the Apple platform it's possible to observe filesystems and receive events of files created, updated, etc.
Nothing is yet implemented to support this - or to handle the document resolver state machine and process in repo, to coordinate updates originating from the filesystem.
This is an area for future growth and/or contribution.

### Network Plugins/Providers

The internal class `NetworkSubsystem` acts as the delegate/connection point to added providers, but is only responsible for coalescing and routing events to and from any network providers.
There are a subset of the total possible SyncV1 messages defined in the Automerge-repo sync protocol that are expected to only be handled by the providers: `peer`, `join`, and `leave`.
These dealing primarily for setting up and authorizing the connection (the Sync Protocol handshake), or polite connection termination.
The `NetworkSubsystem` swallows those and doesn't forward them, but may log that they happened. In a `DEBUG` build, if the Network Systems receives those messages, it will (intentionally) crash.
In `RELEASE` mode, it ignores the messages.

A network provider can support incoming, outgoing connections, or both, but does not have to support more than 1 connection.
The WebSocket provider, for example, only supports a single, outgoing connection.
The PeerToPeer provider supports multiple connections, both incoming and outgoing.

The general pattern for enabling a network provider is that initializing it.
The app using this library is expected to hold on to a reference to the provider to control it starting or stoping listening, and to initiate a connection.
The call to add the provider invokes the providers `setDelegate` method, which is intended to "finish configuring" the provider with information from the repository.
In general, it needs to know the PeerID of the repository, as well as details about storage subsystems (captured in `PeerMetadata`).
These properties need to be set before it can be connected, or accept connections.

Because a provider can be its own isolation domain in Swift 6, the calls to do this setup are all intentionally asynchronous.
Due to that, adding network providers also needs to be done within an async context.

## Automerge-repo (v1) Sync Protocol

The formal definition and documentation for the protocol is hosted in the automerge-repo repository, detailed in the file https://github.com/automerge/automerge-repo/blob/main/packages/automerge-repo-network-websocket/README.md

## WebSocket Network Provider

WebSocketProvider wraps `URLSessionWebSocketTask` and maintains a bit of state about the connection. 
It supports a single, outgoing connection - typically to an instance of the javascript automerge-repo project.
It accepts a configuration instance on initialization, which today only controls if the WebSocket connection will attempt to reconnect on an unexpected loss of the connection.

Because its a single, point to point, connection - there are not any combine publishers for state updates.
Instead, the state is exposed through the `peeredConnection` property, which in this case only ever returns a single result.

That result provides:
- The peerId of the connected endpoint.
- Any storage metadata about that peer.
- The name of the endpoint (the WebSocket URL in this case).
- A Boolean value that represents whether this connection was initiated (always true with an active connection from this provider).
- A Boolean value that indicates whether the connection is peered (meaning the handshake phase of the sync protocol has been completed).

There's an async `connect(to:)` and `disconnect()` to establish the connection, as well as an async `send(message:to:)`.
The general code flow establishes the connection, and then uses a detached task (that the provider manages), to do ongoing receive next message (`ongoingReceiveWebSocketMessages()`) and pass any relevant messages up to the network subsystem and repository.
The logic for handshaking (`attemptConnect(to:) -> URLSessionWebSocketTask?`) and reconnect is included in this loop, and uses a Fibonacci-based backoff delay if the connection fails to reconnect.

All the WebSocket messages are binary CBOR encoded, so this provider is also responsible for decoding the messages before passing them on as an enumeration (`SyncV1Msg`) instance, sometimes with additional payloads or metadata.
A failed message decode doesn't terminate anything, instead the message is ignored.
String WebSocket messages are unexpected and ignored (although logged).

The function `nextMessage` is specifically created to wrap the URLSessionWebSocketTask async `receive()` call, and race it against a timeout. 
It is primarily used during the handshake process, as the ongoing receive loop doesn't incorporate a timeout between messages.

## PeerToPeer Network Provider

