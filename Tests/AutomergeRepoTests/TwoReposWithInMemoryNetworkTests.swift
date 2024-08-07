import Automerge
@testable import AutomergeRepo
import AutomergeUtilities
import Foundation
import RegexBuilder
import Tracing
import XCTest

final class TwoReposWithInMemoryNetworkTests: XCTestCase {
    let network = InMemoryNetwork.shared
    var repo_nonsharing: Repo!
    var repo_sharing: Repo!

    var adapterOne: InMemoryNetworkEndpoint!
    var adapterTwo: InMemoryNetworkEndpoint!

    override func setUp() async throws {
        // await TestTracer.shared.bootstrap(serviceName: "RepoTests")
        await withSpan("setUp") { _ in

            await withSpan("resetTestNetwork") { _ in
                await network.resetTestNetwork()
            }

            await withSpan("TwoReposWithNetworkTests_setup") { _ in

                let endpoints = await self.network.endpoints
                XCTAssertEqual(endpoints.count, 0)

                repo_nonsharing = Repo(sharePolicy: SharePolicy.readonly)
                // Repo setup WITHOUT any storage subsystem
                let storageId = await repo_nonsharing.storageId()
                XCTAssertNil(storageId)

                adapterOne = await network.createNetworkEndpoint(
                    config: .init(
                        listeningNetwork: false,
                        name: "One"
                    )
                )
                await repo_nonsharing.addNetworkAdapter(adapter: adapterOne)

                let peersOne = await repo_nonsharing.peers()
                XCTAssertEqual(peersOne, [])

                repo_sharing = Repo(sharePolicy: SharePolicy.agreeable)
                adapterTwo = await network.createNetworkEndpoint(
                    config: .init(
                        listeningNetwork: true,
                        name: "Two"
                    )
                )
                await repo_sharing.addNetworkAdapter(adapter: adapterTwo)

                let peersTwo = await repo_sharing.peers()
                XCTAssertEqual(peersTwo, [])

                let connections = await network.connections()
                XCTAssertEqual(connections.count, 0)

                let endpointRecount = await network.endpoints
                XCTAssertEqual(endpointRecount.count, 2)
            }
        }
    }

    override func tearDown() async throws {
//        if let tracer = await TestTracer.shared.tracer {
//            tracer.forceFlush()
//            // Testing does NOT have a polite shutdown waiting for a flush to complete, so
//            // we explicitly give it some extra time here to flush out any spans remaining.
//            try await Task.sleep(for: .seconds(1))
//        }
    }

    func testMostBasicRepoStartingPoints() async throws {
        // Repo
        //  property: peers [PeerId] - all (currently) connected peers
        let peersOne = await repo_nonsharing.peers()
        let peersTwo = await repo_sharing.peers()
        XCTAssertEqual(peersOne, [])
        XCTAssertEqual(peersOne, peersTwo)

        let knownIdsOne = await repo_nonsharing.documentIds()
        XCTAssertEqual(knownIdsOne, [])

        let knownIdsTwo = await repo_nonsharing.documentIds()
        XCTAssertEqual(knownIdsTwo, knownIdsOne)
    }

    func testCreateNetworkEndpoint() async throws {
        let _ = await network.createNetworkEndpoint(
            config: .init(
                listeningNetwork: false,
                name: "Z"
            )
        )
        let endpoints = await network.endpoints
        XCTAssertEqual(endpoints.count, 3)
        let z = endpoints["Z"]
        XCTAssertNotNil(z)
    }

    func testConnect() async throws {
        // Enable the following line to see the messages from the connections
        // point of view:

        // await network.traceConnections(true)

        // Enable logging of received for the adapter:
        await adapterOne.logReceivedMessages(true)
        await adapterTwo.logReceivedMessages(true)
        // Logging doesn't show up in exported test output - it's interleaved into Xcode's console
        // which is useful for debugging tests

        try await withSpan("testConnect") { _ in
            try await adapterOne.connect(to: "Two")

            let connectionIdFromOne = await adapterOne._connections.first?.id
            let connectionIdFromTwo = await adapterTwo._connections.first?.id
            XCTAssertEqual(connectionIdFromOne, connectionIdFromTwo)

            let peersOne = await adapterOne.peeredConnections
            let peersTwo = await adapterTwo.peeredConnections
            XCTAssertFalse(peersOne.isEmpty)
            XCTAssertFalse(peersTwo.isEmpty)
        }
    }

    func testCreate() async throws {
        try await withSpan("testCreate") { _ in

            // initial conditions
            var knownOnTwo = await repo_sharing.documentIds()
            var knownOnOne = await repo_nonsharing.documentIds()
            XCTAssertEqual(knownOnOne.count, 0)
            XCTAssertEqual(knownOnTwo.count, 0)

            // Create and add some doc content to the "server" repo - RepoTwo
            let newDocId = DocumentId()
            let newDoc = try await withSpan("repoTwo.create") { _ in
                try await repo_sharing.create(id: newDocId)
            }
            // add some content to the new document
            try newDoc.doc.put(obj: .ROOT, key: "title", value: .String("INITIAL VALUE"))

            XCTAssertNotNil(newDoc)
            knownOnTwo = await repo_sharing.documentIds()
            XCTAssertEqual(knownOnTwo.count, 1)
            XCTAssertEqual(knownOnTwo[0], newDocId)

            knownOnOne = await repo_nonsharing.documentIds()
            XCTAssertEqual(knownOnOne.count, 0)

            let twoSyncExpectation = expectation(description: "Repo Two should attempt to sync when repo one connects")
            var expectationMet = false
            let two_sink = repo_sharing.syncRequestPublisher.sink { syncRequest in
                if syncRequest.id == newDocId, syncRequest.peer == self.repo_nonsharing.peerId {
                    if !expectationMet {
                        expectationMet = true
                        twoSyncExpectation.fulfill()
                    }
                }
            }
            XCTAssertNotNil(twoSyncExpectation)

            // "GO ONLINE"
            // await network.traceConnections(true)
            // await adapterTwo.logReceivedMessages(true)
            try await withSpan("adapterOne.connect") { _ in
                try await adapterOne.connect(to: "Two")
            }

            await fulfillment(of: [twoSyncExpectation], timeout: 30)
            two_sink.cancel()

            // verify that after sync, both repos have a copy of the document
            knownOnOne = await repo_nonsharing.documentIds()
            XCTAssertEqual(knownOnOne.count, 1)
            XCTAssertEqual(knownOnOne[0], newDocId)
        }
    }

    func testFind_sharing() async throws {
        // initial conditions
        let knownOnTwo = await repo_sharing.documentIds()
        let knownOnOne = await repo_nonsharing.documentIds()
        XCTAssertEqual(knownOnOne.count, 0)
        XCTAssertEqual(knownOnTwo.count, 0)

        // "GO ONLINE"
        // await network.traceConnections(true)
        // await adapterTwo.logReceivedMessages(true)
        try await withSpan("repo_nonsharing.connect") { _ in
            try await adapterOne.connect(to: "Two")
        }

        // Create and add some doc content to the "server" repo - RepoTwo
        let newDocId = DocumentId()
        let newDoc = try await withSpan("repo_sharing.create") { _ in
            try await repo_sharing.create(id: newDocId)
        }
        XCTAssertNotNil(newDoc.doc)
        // add some content to the new document
        try newDoc.doc.put(obj: .ROOT, key: "title", value: .String("INITIAL VALUE"))

        await repo_nonsharing.setLogLevel(.resolver, to: .tracing)
        await repo_nonsharing.setLogLevel(.network, to: .tracing)
        // We can _request_ the document, and should find it - but it won't YET be updated...
        let foundDoc = try await repo_nonsharing.find(id: newDocId)

        // set up expectation to await for trigger from the objectWillChange publisher on the "found" doc
        let documentsEquivalent = expectation(
            description: "The document should eventually become equivalent"
        )

        var fulfilledOnce = false
        let a = foundDoc.doc.objectWillChange.receive(on: DispatchQueue.main).sink { _ in
            if !fulfilledOnce, foundDoc.doc.getHistory() == newDoc.doc.getHistory() {
                documentsEquivalent.fulfill()
                fulfilledOnce = true
            }
        }
        XCTAssertNotNil(a)
        await fulfillment(of: [documentsEquivalent], timeout: 10, enforceOrder: false)
    }

    func testFind_nonsharing() async throws {
        // initial conditions
        let knownOnTwo = await repo_sharing.documentIds()
        let knownOnOne = await repo_nonsharing.documentIds()
        XCTAssertEqual(knownOnOne.count, 0)
        XCTAssertEqual(knownOnTwo.count, 0)

        // "GO ONLINE"
        // await network.traceConnections(true)
        // await adapterTwo.logReceivedMessages(true)
        try await withSpan("repo_nonsharing.connect") { _ in
            try await adapterOne.connect(to: "Two")
        }

        // Create and add some doc content to the "server" repo - RepoTwo
        let newDocId = DocumentId()
        let newDoc = try await withSpan("repo_nonsharing.create") { _ in
            try await repo_nonsharing.create(id: newDocId)
        }
        XCTAssertNotNil(newDoc.doc)
        // add some content to the new document
        try newDoc.doc.put(obj: .ROOT, key: "title", value: .String("INITIAL VALUE"))

        await repo_nonsharing.setLogLevel(.resolver, to: .tracing)
        await repo_nonsharing.setLogLevel(.network, to: .tracing)
        // We can _request_ the document, but a non-sharing repo won't provide it
        do {
            let _ = try await repo_sharing.find(id: newDocId)
            XCTFail("Expected unavailable response")
        } catch let error as Errors.Unavailable {
            XCTAssertEqual(error.id, newDocId)
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testFindFail() async throws {
        // initial conditions
        var knownOnTwo = await repo_sharing.documentIds()
        var knownOnOne = await repo_nonsharing.documentIds()
        XCTAssertEqual(knownOnOne.count, 0)
        XCTAssertEqual(knownOnTwo.count, 0)

        // Create and add some doc content to the "client" repo - RepoOne
        let newDocId = DocumentId()
        let newDoc = try await withSpan("repoTwo.create") { _ in
            try await repo_nonsharing.create(id: newDocId)
        }
        XCTAssertNotNil(newDoc.doc)
        // add some content to the new document
        try newDoc.doc.put(obj: .ROOT, key: "title", value: .String("INITIAL VALUE"))

        knownOnTwo = await repo_sharing.documentIds()
        XCTAssertEqual(knownOnTwo.count, 0)

        knownOnOne = await repo_nonsharing.documentIds()
        XCTAssertEqual(knownOnOne.count, 1)
        XCTAssertEqual(knownOnOne[0], newDocId)
        // "GO ONLINE"
        await network.traceConnections(true)
        // await adapterTwo.logReceivedMessages(true)
        try await withSpan("adapterOne.connect") { _ in
            try await adapterOne.connect(to: "Two")
        }

        // Two doesn't automatically get the document because RepoOne
        // isn't configured to "share" automatically on connect
        // (it's not "agreeable")
        knownOnTwo = await repo_sharing.documentIds()
        XCTAssertEqual(knownOnTwo.count, 0)

        knownOnOne = await repo_nonsharing.documentIds()
        XCTAssertEqual(knownOnOne.count, 1)

        // We can _request_ the document, but should be denied
        do {
            let _ = try await repo_sharing.find(id: newDocId)
            XCTFail("RepoOne is private and should NOT share the document")
        } catch {
            let errMsg = error.localizedDescription
            print(errMsg)
        }
    }

    // TBD:
    // - func storageIdForPeer(peerId) -> StorageId
    // - func subscribeToRemotes([StorageId])
}
