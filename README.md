# AutomergeRepo, swift edition

Extends the [Automerge-swift](https://github.com/automerge/automerge-swift) library, providing support for working with multiple Automerge documents at once, with pluggable network and storage providers.

The library is a functional port/replica of the [automerge-repo](https://github.com/automerge/automerge-repo) javascript library.
The goal of this project is to provide convenient storage and network synchronization for one or more Automerge documents, concurrently with multiple network peers.

This library is being extracted from the Automerge-swift demo application [MeetingNotes](https://github.com/automerge/MeetingNotes).
As such, the API is far from stable, and some not-swift6-compatible classes remain while we continue to evolve this library.

## Quickstart

> WARNING: This package does NOT yet have a release tagged. Once the legacy elements from the MeetingNotes app are fully ported into Repo, we will cut an initial release for this package. In the meantime, if you want to explore or use this package, please do so as a local Package depdendency.


**PENDING A RELEASE**, add a dependency in `Package.swift`, as the following example shows:

```swift
let package = Package(
    ...
    dependencies: [
        ...
        .package(url: "https://github.com/automerge/automerge-repo-swift.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            ...
            dependencies: [.product(name: "AutomergeRepo", package: "automerge-repo-swift")],
            ...
        )
    ]
)
```

For more details on using Automerge Documents, see the [Automerge-swift API documentation](https://automerge.org/automerge-swift/documentation/automerge/) and the articles within.
