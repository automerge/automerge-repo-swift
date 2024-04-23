import Automerge
import AutomergeRepo
import AutomergeUtilities
import OSLog
import XCTest

final class RepoPeer2PeerIntegrationTests: XCTestCase {
    private static let subsystem = Bundle.main.bundleIdentifier!

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

        var alicePeers: [AvailablePeer] = []
        let a = p2pAlice.availablePeerPublisher.receive(on: RunLoop.main).sink { peerList in
            print("FOUND \(peerList)")
            alicePeers = peerList
        }
        XCTAssertNotNil(a)

        var bobPeers: [AvailablePeer] = []
        let b = p2pBob.availablePeerPublisher.receive(on: RunLoop.main).sink { peerList in
            bobPeers = peerList
        }
        XCTAssertNotNil(b)

        // give it a couple seconds for the networks to stabilize and see each other...
        try await Task.sleep(for: .seconds(5))
        XCTAssertEqual(alicePeers.count, 2)
        XCTAssertEqual(bobPeers.count, 2)
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

        var alicePeers: [AvailablePeer] = []
        let a_p = p2pAlice.availablePeerPublisher.receive(on: RunLoop.main).sink { peerList in
            print("FOUND \(peerList)")
            alicePeers = peerList
        }
        XCTAssertNotNil(a_p)

        var aliceConnections: [PeerConnectionInfo] = []
        let a_c = p2pAlice.connectionPublisher.receive(on: RunLoop.main).sink { connectList in
            aliceConnections = connectList
        }
        XCTAssertNotNil(a_c)

        var bobConnections: [PeerConnectionInfo] = []
        let b_c = p2pBob.connectionPublisher.receive(on: RunLoop.main).sink { connectList in
            bobConnections = connectList
        }
        XCTAssertNotNil(b_c)

        // give it a couple seconds for the networks to stabilize and see each other...
        try await Task.sleep(for: .seconds(5))
        XCTAssertEqual(alicePeers.count, 2)
        let peerToConnect = try XCTUnwrap(
            alicePeers.first { ap in
                ap.peerId != repoAlice.peerId
            }
        )

        // verify the state of documents within each of the two peer repo BEFORE we connect

        var aliceDocs = await repoAlice.documentIds()
        XCTAssertEqual(aliceDocs.count, 1)
        XCTAssertEqual(aliceDocs[0], handle.id)
        var bobDocs = await repoBob.documentIds()
        XCTAssertEqual(bobDocs.count, 0)

        // MARK: CONNECT TO PEER

        try await p2pAlice.connect(to: peerToConnect.endpoint)
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(bobConnections.count, aliceConnections.count)
        XCTAssertEqual(aliceConnections[0].peerId, repoBob.peerId)
        XCTAssertEqual(aliceConnections[0].peered, true)
        XCTAssertEqual(aliceConnections[0].initiated, true)

        XCTAssertEqual(bobConnections[0].peerId, repoAlice.peerId)
        XCTAssertEqual(bobConnections[0].peered, true)
        XCTAssertEqual(bobConnections[0].initiated, false)

        // verify the state of documents within each of the two peer repo AFTER we connect

        aliceDocs = await repoAlice.documentIds()
        XCTAssertEqual(aliceDocs.count, 1)
        XCTAssertEqual(aliceDocs[0], handle.id)
        bobDocs = await repoBob.documentIds()
        XCTAssertEqual(bobDocs.count, 0)
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

        var alicePeers: [AvailablePeer] = []
        let a_p = p2pAlice.availablePeerPublisher.receive(on: RunLoop.main).sink { peerList in
            print("FOUND \(peerList)")
            alicePeers = peerList
        }
        XCTAssertNotNil(a_p)

        var aliceConnections: [PeerConnectionInfo] = []
        let a_c = p2pAlice.connectionPublisher.receive(on: RunLoop.main).sink { connectList in
            aliceConnections = connectList
        }
        XCTAssertNotNil(a_c)

        // give it a couple seconds for the networks to stabilize and see each other...
        try await Task.sleep(for: .seconds(6))

        XCTAssertEqual(alicePeers.count, 2)
        let peerToConnect = try XCTUnwrap(
            alicePeers.first { ap in
                ap.peerId != repoAlice.peerId
            }
        )

        // verify the state of documents within each of the two peer repo BEFORE we connect

        var aliceDocs = await repoAlice.documentIds()
        XCTAssertEqual(aliceDocs.count, 1)
        XCTAssertEqual(aliceDocs[0], handle.id)
        var bobDocs = await repoBob.documentIds()
        XCTAssertEqual(bobDocs.count, 0)

        // MARK: CONNECT TO PEER

        try await p2pAlice.connect(to: peerToConnect.endpoint)
        try await Task.sleep(for: .seconds(2))

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
    }
}
