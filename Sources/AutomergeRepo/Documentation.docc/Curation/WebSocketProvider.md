# ``AutomergeRepo/WebSocketProvider``

## Overview

Create and retain a reference to an instance of `WebSocketProvider` to establish a point to point connection, using WebSockets, to another Automerge repository, for example a service built with the JavaScript library [automerge-repo](https://github.com/automerge/automerge-repo).

After creating the network provider, add it to ``Repo`` using ``Repo/addNetworkAdapter(adapter:)``.
For example, the [MeetingNotes demo application](https://github.com/automerge/MeetingNotes/) creates a single global instance and adds it to a repository in a Task that is invoked immediately after the app initializes:


```swift
let repo = Repo(sharePolicy: SharePolicy.agreeable)
let websocket = WebSocketProvider(.init(reconnectOnError: true, loggingAt: .tracing))

@main
struct MeetingNotesApp: App {
    ...

    init() {
        Task {
            // Enable network adapters
            await repo.addNetworkAdapter(adapter: websocket)
        }
    }
}
```

To connect the repository to a remote endpoint, make an async call to ``connect(to:)``, passing the WebSocket URL:

```swift
Button {    
    Task {
        try await websocket.connect(to: repoDestination.url)
    }
} label: {
    Text("Connect")
}
```

## Topics

### Creating a WebSocket network provider

- ``init(_:)``
- ``WebSocketProviderConfiguration``
- ``ProviderConfiguration``

### Configuring the provider

- ``setDelegate(_:as:with:)``

### Establishing Connections

- ``connect(to:)``
- ``disconnect()``

### Sending messages

- ``send(message:to:)``

### Inspecting the provider

- ``name``
- ``peeredConnections``

### Receiving state updates

- ``statePublisher``
