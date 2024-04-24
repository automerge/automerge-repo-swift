import Automerge
@testable import AutomergeRepo
import XCTest

final class ObservingChangesTest: XCTestCase {
    let network = InMemoryNetwork.shared
    var repoOne: Repo!
    var repoTwo: Repo!

    var adapterOne: InMemoryNetworkEndpoint!
    var adapterTwo: InMemoryNetworkEndpoint!

    override func setUp() async throws {
        await network.resetTestNetwork()
        repoOne = Repo(sharePolicy: SharePolicy.readonly)
        adapterOne = await network.createNetworkEndpoint(
            config: .init(
                listeningNetwork: false,
                name: "EndpointOne"
            )
        )
        await repoOne.addNetworkAdapter(adapter: adapterOne)

        repoTwo = Repo(sharePolicy: SharePolicy.agreeable)
        adapterTwo = await network.createNetworkEndpoint(
            config: .init(
                listeningNetwork: true,
                name: "EndpointTwo"
            )
        )
        await repoTwo.addNetworkAdapter(adapter: adapterTwo)

        let connections = await network.connections()
        XCTAssertEqual(connections.count, 0)

        let endpointRecount = await network.endpoints
        XCTAssertEqual(endpointRecount.count, 2)
    }

    override func tearDown() async throws {}

    func testCreateAndObserveChange() async throws {
        // initial conditions
        var knownOnTwo = await repoTwo.documentIds()
        var knownOnOne = await repoOne.documentIds()
        XCTAssertEqual(knownOnOne.count, 0)
        XCTAssertEqual(knownOnTwo.count, 0)

        // Create and add some doc content to the "server" repo - RepoTwo
        let newDocId = DocumentId()
        let newDoc = try await repoTwo.create(id: newDocId)

        // add some content to the new document
        try newDoc.doc.put(obj: .ROOT, key: "title", value: .String("INITIAL VALUE"))

        XCTAssertNotNil(newDoc)
        knownOnTwo = await repoTwo.documentIds()
        XCTAssertEqual(knownOnTwo.count, 1)
        XCTAssertEqual(knownOnTwo[0], newDocId)

        knownOnOne = await repoOne.documentIds()
        XCTAssertEqual(knownOnOne.count, 0)

        // "GO ONLINE"
        // await network.traceConnections(true)
        // await adapterTwo.logReceivedMessages(true)

        try await adapterOne.connect(to: "EndpointTwo")

        let twoSyncExpectation = expectation(description: "Repo Two should attempt to sync when repo one connects")
        let two_sink = repoTwo.syncRequestPublisher.sink { syncRequest in
            if syncRequest.id == newDocId, syncRequest.peer == self.repoOne.peerId {
                twoSyncExpectation.fulfill()
            }
        }
        XCTAssertNotNil(twoSyncExpectation)
        await fulfillment(of: [twoSyncExpectation], timeout: 10)
        two_sink.cancel()

        // verify that after sync, both repos have a copy of the document
        knownOnOne = await repoOne.documentIds()
        XCTAssertEqual(knownOnOne.count, 1)
        XCTAssertEqual(knownOnOne[0], newDocId)

        // Now verify that Two will attempt to sync AGAIN when the content of the document has changed
        let twoSyncOnContentExpectation =
            expectation(description: "Repo Two should attempt to sync when the content changes")
        let two_sink_content = repoTwo.syncRequestPublisher.sink { syncRequest in
            if syncRequest.id == newDocId, syncRequest.peer == self.repoOne.peerId {
                twoSyncOnContentExpectation.fulfill()
            }
        }
        XCTAssertNotNil(twoSyncOnContentExpectation)
        // making this change _should_ trigger the initial repo to sync
        try newDoc.doc.put(obj: .ROOT, key: "title", value: .String("UPDATED VALUE"))

        await fulfillment(of: [twoSyncOnContentExpectation], timeout: 10)
        two_sink_content.cancel()
    }
}
