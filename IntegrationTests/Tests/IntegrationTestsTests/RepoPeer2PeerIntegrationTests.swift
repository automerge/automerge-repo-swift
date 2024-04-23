import Automerge
import AutomergeRepo
import AutomergeUtilities
import OSLog
import XCTest

final class RepoPeer2PeerIntegrationTests: XCTestCase {
    private static let subsystem = Bundle.main.bundleIdentifier!
    
    let expectationTimeOut = 120.0 // seconds

    static let test = Logger(subsystem: subsystem, category: "RepoPeer2PeerIntegrationTests")

    override func setUp() async throws {}

    override func tearDown() async throws {}

    // document structure for test
    struct ExampleStruct: Identifiable, Codable, Hashable {
        let id: UUID
        var title: String
        var discussion: AutomergeText

        init(title: String, discussion: String) {
            id = UUID()
            self.title = title
            self.discussion = AutomergeText(discussion)
        }
    }

    func addContent(_ doc: Document) throws {
        // initial setup and encoding of Automerge doc to sync it
        let encoder = AutomergeEncoder(doc: doc)
        let model = ExampleStruct(title: "new item", discussion: "editable text")
        try encoder.encode(model)
    }

    func testPeerVisibility() async throws {
        // set up repo (with a client-websocket)
        let repoAlice = Repo(sharePolicy: SharePolicy.agreeable)
        let p2pAlice = PeerToPeerProvider(.init(passcode: "1234"))
        await repoAlice.addNetworkAdapter(adapter: p2pAlice)
        try await p2pAlice.startListening(as: "Alice")

        let repoBob = Repo(sharePolicy: SharePolicy.agreeable)
        let p2pBob = PeerToPeerProvider(.init(passcode: "1234"))
        await repoBob.addNetworkAdapter(adapter: p2pBob)
        try await p2pBob.startListening(as: "Bob")

        // add the document to the Alice repo
        let handle: DocHandle = try await repoAlice.create(doc: Document(), id: DocumentId())
        try addContent(handle.doc)

        // With the websocket protocol, we don't get confirmation of a sync being complete -
        // if the other side has everything and nothing new, they just won't send a response
        // back. In that case, we don't get any further responses - but we don't _know_ that
        // it's complete. In an initial sync there will always be at least one response, but
        // we can't quite count on this always being an initial sync... so I'm shimming in a
        // short "wait" here to leave the background tasks that receive WebSocket messages
        // running to catch any updates, and hoping that'll be enough time to complete it.

        let alicePeersExpectation = expectation(description: "Repo 'Alice' sees two peers")
        let bobPeersExpectation = expectation(description: "Repo 'Bob' sees two peers")

        let a = p2pAlice.availablePeerPublisher.receive(on: RunLoop.main).sink { peerList in
            if peerList.count == 2,
               peerList.contains(where: { ap in
                   ap.peerId == repoBob.peerId
               }),
               peerList.contains(where: { ap in
                   ap.peerId == repoAlice.peerId
               })
            {
                alicePeersExpectation.fulfill()
            }
        }
        XCTAssertNotNil(a)

        let b = p2pBob.availablePeerPublisher.receive(on: RunLoop.main).sink { peerList in
            if peerList.count == 2,
               peerList.contains(where: { ap in
                   ap.peerId == repoBob.peerId
               }),
               peerList.contains(where: { ap in
                   ap.peerId == repoAlice.peerId
               })
            {
                bobPeersExpectation.fulfill()
            }
        }
        XCTAssertNotNil(b)

        await fulfillment(of: [alicePeersExpectation, bobPeersExpectation], timeout: expectationTimeOut, enforceOrder: false)
        
        // MARK: cleanup and teardown
        
        await p2pAlice.disconnect()
        await p2pAlice.stopListening()
        await p2pBob.disconnect()
        await p2pBob.stopListening()
    }

    func testPeerExplicitConnect() async throws {
        // set up repo (with a client-websocket)
        let repoAlice = Repo(sharePolicy: SharePolicy.agreeable)
        let p2pAlice = PeerToPeerProvider(.init(passcode: "1234"))
        await repoAlice.addNetworkAdapter(adapter: p2pAlice)
        try await p2pAlice.startListening(as: "Alice")

        let repoBob = Repo(sharePolicy: SharePolicy.agreeable)
        let p2pBob = PeerToPeerProvider(.init(passcode: "1234"))
        await repoBob.addNetworkAdapter(adapter: p2pBob)
        try await p2pBob.startListening(as: "Bob")

        // add the document to the Alice repo
        let handle: DocHandle = try await repoAlice.create(doc: Document(), id: DocumentId())
        try addContent(handle.doc)

        // With the websocket protocol, we don't get confirmation of a sync being complete -
        // if the other side has everything and nothing new, they just won't send a response
        // back. In that case, we don't get any further responses - but we don't _know_ that
        // it's complete. In an initial sync there will always be at least one response, but
        // we can't quite count on this always being an initial sync... so I'm shimming in a
        // short "wait" here to leave the background tasks that receive WebSocket messages
        // running to catch any updates, and hoping that'll be enough time to complete it.

        let alicePeersExpectation = expectation(description: "Repo 'Alice' sees two peers")
        let aliceConnectionExpectation = expectation(description: "Repo 'Alice' sees a connection to Bob")
        let bobConnectionExpectation = expectation(description: "Repo 'Bob' sees a connection to Alice")
        var peerToConnect: AvailablePeer? = nil

        let a = p2pAlice.availablePeerPublisher.receive(on: RunLoop.main).sink { peerList in
            if peerList.count == 2,
               peerList.contains(where: { ap in
                   ap.peerId == repoBob.peerId
               }),
               peerList.contains(where: { ap in
                   ap.peerId == repoAlice.peerId
               })
            {
                // stash away the endpoint so that we can connect to it.
                peerToConnect = peerList.first { ap in
                    ap.peerId != repoAlice.peerId
                }

                alicePeersExpectation.fulfill()
            }
        }
        XCTAssertNotNil(a)

        await fulfillment(of: [alicePeersExpectation], timeout: expectationTimeOut, enforceOrder: false)

        let a_c = p2pAlice.connectionPublisher.receive(on: RunLoop.main).sink { connectList in
            if connectList.count == 1,
               connectList.contains(where: { connection in
                   connection.initiated == true &&
                       connection.peered == true &&
                       connection.peerId == repoBob.peerId
               })
            {
                aliceConnectionExpectation.fulfill()
            }
        }
        XCTAssertNotNil(a_c)

        let b_c = p2pBob.connectionPublisher.receive(on: RunLoop.main).sink { connectList in
            if connectList.count == 1,
               connectList.contains(where: { connection in
                   connection.initiated == false &&
                       connection.peered == true &&
                       connection.peerId == repoAlice.peerId
               })
            {
                bobConnectionExpectation.fulfill()
            }
        }
        XCTAssertNotNil(b_c)

        // verify the state of documents within each of the two peer repo BEFORE we connect

        var aliceDocs = await repoAlice.documentIds()
        XCTAssertEqual(aliceDocs.count, 1)
        XCTAssertEqual(aliceDocs[0], handle.id)
        var bobDocs = await repoBob.documentIds()
        XCTAssertEqual(bobDocs.count, 0)

        // MARK: CONNECT TO PEER

        let unwrappedPeerToConnect = try XCTUnwrap(peerToConnect)
        try await p2pAlice.connect(to: unwrappedPeerToConnect.endpoint)

        await fulfillment(of: [aliceConnectionExpectation, bobConnectionExpectation], timeout: expectationTimeOut, enforceOrder: false)

        // verify the state of documents within each of the two peer repo AFTER we connect

        aliceDocs = await repoAlice.documentIds()
        XCTAssertEqual(aliceDocs.count, 1)
        XCTAssertEqual(aliceDocs[0], handle.id)
        // Note: no auto-sync on connect, so Bob's repo doesn't yet see the document we added to Alice's repo
        bobDocs = await repoBob.documentIds()
        XCTAssertEqual(bobDocs.count, 0)

        // MARK: cleanup and teardown
        
        await p2pAlice.disconnect()
        await p2pAlice.stopListening()
        await p2pBob.disconnect()
        await p2pBob.stopListening()
    }

    func testPeerExplicitConnectAndFind() async throws {
        // set up repo (with a client-websocket)
        let repoAlice = Repo(sharePolicy: SharePolicy.agreeable)
        let p2pAlice = PeerToPeerProvider(.init(passcode: "1234"))
        await repoAlice.addNetworkAdapter(adapter: p2pAlice)
        try await p2pAlice.startListening(as: "Alice")

        let repoBob = Repo(sharePolicy: SharePolicy.agreeable)
        let p2pBob = PeerToPeerProvider(.init(passcode: "1234"))
        await repoBob.addNetworkAdapter(adapter: p2pBob)
        try await p2pBob.startListening(as: "Bob")

        // add the document to the Alice repo
        let handle: DocHandle = try await repoAlice.create(doc: Document(), id: DocumentId())
        try addContent(handle.doc)

        // With the websocket protocol, we don't get confirmation of a sync being complete -
        // if the other side has everything and nothing new, they just won't send a response
        // back. In that case, we don't get any further responses - but we don't _know_ that
        // it's complete. In an initial sync there will always be at least one response, but
        // we can't quite count on this always being an initial sync... so I'm shimming in a
        // short "wait" here to leave the background tasks that receive WebSocket messages
        // running to catch any updates, and hoping that'll be enough time to complete it.

        let alicePeersExpectation = expectation(description: "Repo 'Alice' sees two peers")
        var peerToConnect: AvailablePeer? = nil

        let a = p2pAlice.availablePeerPublisher.receive(on: RunLoop.main).sink { peerList in
            if peerList.count == 2,
               peerList.contains(where: { ap in
                   ap.peerId == repoBob.peerId
               }),
               peerList.contains(where: { ap in
                   ap.peerId == repoAlice.peerId
               })
            {
                // stash away the endpoint so that we can connect to it.
                peerToConnect = peerList.first { ap in
                    ap.peerId != repoAlice.peerId
                }

                alicePeersExpectation.fulfill()
            }
        }
        XCTAssertNotNil(a)

        await fulfillment(of: [alicePeersExpectation], timeout: expectationTimeOut, enforceOrder: false)

        // verify the state of documents within each of the two peer repo BEFORE we connect

        var aliceDocs = await repoAlice.documentIds()
        XCTAssertEqual(aliceDocs.count, 1)
        XCTAssertEqual(aliceDocs[0], handle.id)
        var bobDocs = await repoBob.documentIds()
        XCTAssertEqual(bobDocs.count, 0)

        // MARK: CONNECT TO PEER

        let unwrappedPeerToConnect = try XCTUnwrap(peerToConnect)
        try await p2pAlice.connect(to: unwrappedPeerToConnect.endpoint)

        // verify the state of documents within each of the two peer repo AFTER we connect

        aliceDocs = await repoAlice.documentIds()
        XCTAssertEqual(aliceDocs.count, 1)
        XCTAssertEqual(aliceDocs[0], handle.id)
        bobDocs = await repoBob.documentIds()
        XCTAssertEqual(bobDocs.count, 0)

        // MARK: make the explicit request for a document across the peer network

        let requestedDoc = try await repoBob.find(id: handle.id)
        XCTAssertEqual(requestedDoc.id, handle.id)
        XCTAssertTrue(RepoHelpers.equalContents(doc1: requestedDoc.doc, doc2: handle.doc))
        
        // MARK: cleanup and teardown
        
        await p2pAlice.disconnect()
        await p2pAlice.stopListening()
        await p2pBob.disconnect()
        await p2pBob.stopListening()
    }
}
