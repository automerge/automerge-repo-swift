import Automerge
import AutomergeRepo
import AutomergeUtilities
import OSLog
import XCTest
import Combine

// NOTE(heckj): This integration test expects that you have a websocket server with the
// Automerge-repo sync protocol running at localhost:3030. If you're testing from the local
// repository, run the `./scripts/interop.sh` script to start up a local instance to
// respond.

final class RepoAndTwoClientWebsocketIntegrationTests: XCTestCase {
    private static let subsystem = Bundle.main.bundleIdentifier!

    static let test = Logger(subsystem: subsystem, category: "WebSocketSyncIntegrationTests")
    let syncDestination = "ws://localhost:3030/"
    // Switch to the following line to run a test against the public hosted automerge-repo instance
//    let syncDestination = "wss://sync.automerge.org/"

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

    override func setUp() async throws {
        let isWebSocketConnectable = await webSocketAvailable(destination: syncDestination)
        try XCTSkipUnless(isWebSocketConnectable, "websocket unavailable for integration test")
    }

    override func tearDown() async throws {
        // teardown
    }

    func webSocketAvailable(destination: String) async -> Bool {
        guard let url = URL(string: destination) else {
            Self.test.error("invalid URL: \(destination, privacy: .public) - endpoint unavailable")
            return false
        }
        // establishes the websocket
        let request = URLRequest(url: url)
        let ws: URLSessionWebSocketTask = URLSession.shared.webSocketTask(with: request)
        ws.resume()
        Self.test.info("websocket to \(destination, privacy: .public) prepped, sending ping")
        do {
            try await ws.sendPing()
            Self.test.info("PING OK - returning true")
            ws.cancel(with: .normalClosure, reason: nil)
            return true
        } catch {
            Self.test.error("PING FAILED: \(error.localizedDescription, privacy: .public) - returning false")
            ws.cancel(with: .abnormalClosure, reason: nil)
            return false
        }
    }
    
    // MARK: Utilities for the test

    func newConnectedRepo() async throws -> (Repo, WebSocketProvider) {
        // set up repo (with a client-websocket)
        let repo = Repo(sharePolicy: SharePolicy.agreeable)
        let websocket = WebSocketProvider()
        await repo.addNetworkAdapter(adapter: websocket)
        
        // establish connection to remote automerge-repo instance over a websocket
        let url = try XCTUnwrap(URL(string: syncDestination))
        try await websocket.connect(to: url)
        return (repo, websocket)
    }

    func newConnectedRepoWithStorageAdapter() async throws -> (Repo, WebSocketProvider) {
        // set up repo (with a client-websocket)
        let repo = Repo(sharePolicy: SharePolicy.agreeable, storage: InMemoryStorage())
        let websocket = WebSocketProvider()
        await repo.addNetworkAdapter(adapter: websocket)
        
        // establish connection to remote automerge-repo instance over a websocket
        let url = try XCTUnwrap(URL(string: syncDestination))
        try await websocket.connect(to: url)
        return (repo, websocket)
    }

    func createAndStoreDocument(_ id: DocumentId, repo: Repo) async throws -> (DocHandle, [ChangeHash]) {
        // add the document to the repo
        let handle: DocHandle = try await repo.create(id: id)

        // initial setup and encoding of Automerge doc to sync it
        let encoder = AutomergeEncoder(doc: handle.doc)
        let model = ExampleStruct(title: "new item", discussion: "editable text")
        try encoder.encode(model)

        // With the websocket protocol, we don't get confirmation of a sync being complete -
        // if the other side has everything and nothing new, they just won't send a response
        // back. In that case, we don't get any further responses - but we don't _know_ that
        // it's complete. In an initial sync there will always be at least one response, but
        // we can't quite count on this always being an initial sync... so I'm shimming in a
        // short "wait" here to leave the background tasks that receive WebSocket messages
        // running to catch any updates, and hoping that'll be enough time to complete it.
        try await Task.sleep(for: .seconds(5))
        let history = handle.doc.getHistory()
        return (handle, history)
    }
    
    // MARK: The Tests
    
    func testIssue106_Repo_history() async throws {
        // stepping into details from https://github.com/automerge/automerge-repo-swift/issues/106
        // History on the document as soon as it's returned should be equivalent. There should be
        // no need to wait for any change notifications.
        let documentIdForTest = DocumentId()
        let (repoA, websocketA) = try await newConnectedRepo()
        let (_, historyFromCreatedDoc) = try await createAndStoreDocument(documentIdForTest, repo: repoA)
        
        // now establish a new connection, representing a second peer, looking for the data
        let (repoB, websocketB) = try await newConnectedRepo()

        let handle = try await repoB.find(id: documentIdForTest)
        let historyFromFoundDoc = handle.doc.getHistory()
        XCTAssertEqual(historyFromCreatedDoc, historyFromFoundDoc)

        // cleanup
        await websocketA.disconnect()
        await websocketB.disconnect()
    }

    func testIssue106_RepoWithStorage_history() async throws {
        // stepping into details from https://github.com/automerge/automerge-repo-swift/issues/106
        // History on the document as soon as it's returned should be equivalent. There should be
        // no need to wait for any change notifications.
        let documentIdForTest = DocumentId()
        let (repoA, websocketA) = try await newConnectedRepoWithStorageAdapter()
        let (_, historyFromCreatedDoc) = try await createAndStoreDocument(documentIdForTest, repo: repoA)
        
        // now establish a new connection, representing a second peer, looking for the data
        let (repoB, websocketB) = try await newConnectedRepoWithStorageAdapter()

        let handle = try await repoB.find(id: documentIdForTest)
        let historyFromFoundDoc = handle.doc.getHistory()
        XCTAssertEqual(historyFromCreatedDoc, historyFromFoundDoc)

        // cleanup
        await websocketA.disconnect()
        await websocketB.disconnect()
    }

    func testIssue106_Repo_notificationOnChange() async throws {
        let documentIdForTest = DocumentId()
        let (repoA, websocketA) = try await newConnectedRepo()
        let (createdDocHandle, historyFromCreatedDoc) = try await createAndStoreDocument(documentIdForTest, repo: repoA)
        
        // now establish a new connection, representing a second peer, looking for the data
        let (repoB, websocketB) = try await newConnectedRepo()

        let handle = try await repoB.find(id: documentIdForTest)
        let historyFromFoundDoc = handle.doc.getHistory()
        XCTAssertEqual(historyFromCreatedDoc, historyFromFoundDoc)

        // set up expectation to await for trigger from the objectWillChange publisher on the "found" doc
        let documentChangePublisherExpectation = expectation(description: "Document handle from repo 'B' receives a change when the document handle from Repo 'A' is updated")
        let a = handle.doc.objectWillChange.receive(on: DispatchQueue.main).sink { peerList in
            documentChangePublisherExpectation.fulfill()
        }
        XCTAssertNotNil(a)
        // This is loosely the equivalent of the code provided in the issue, but without the prepend
        //    handle.doc.objectWillChange.prepend(()).receive(on: DispatchQueue.main).sink {
        //        print("\(id) history count: \(handle.doc.getHistory().count)")
        //    }
        //    .store(in: &subs)

        // make a change
        let encoder = AutomergeEncoder(doc: createdDocHandle.doc)
        let model = ExampleStruct(title: "updated item", discussion: "editable text")
        try encoder.encode(model)
        // encoding writes into the document, which should initiate the change...
        
        await fulfillment(of: [documentChangePublisherExpectation], timeout: expectationTimeOut, enforceOrder: false)
        
        // and afterwards, their histories should be identical as well.
        XCTAssertEqual(createdDocHandle.doc.getHistory(), handle.doc.getHistory())
        // cleanup
        await websocketA.disconnect()
        await websocketB.disconnect()
    }
    
    func testIssue106_RepoWithStorage_notificationOnChange() async throws {
        let documentIdForTest = DocumentId()
        let (repoA, websocketA) = try await newConnectedRepo()
        let (createdDocHandle, historyFromCreatedDoc) = try await createAndStoreDocument(documentIdForTest, repo: repoA)
        
        // now establish a new connection, representing a second peer, looking for the data
        let (repoB, websocketB) = try await newConnectedRepoWithStorageAdapter()

        let handle = try await repoB.find(id: documentIdForTest)
        let historyFromFoundDoc = handle.doc.getHistory()
        XCTAssertEqual(historyFromCreatedDoc, historyFromFoundDoc)

        // set up expectation to await for trigger from the objectWillChange publisher on the "found" doc
        let documentChangePublisherExpectation = expectation(description: "Document handle from repo 'B' receives a change when the document handle from Repo 'A' is updated")
        let a = handle.doc.objectWillChange.receive(on: DispatchQueue.main).sink { peerList in
            documentChangePublisherExpectation.fulfill()
        }
        XCTAssertNotNil(a)
        // This is loosely the equivalent of the code provided in the issue, but without the prepend
        //    handle.doc.objectWillChange.prepend(()).receive(on: DispatchQueue.main).sink {
        //        print("\(id) history count: \(handle.doc.getHistory().count)")
        //    }
        //    .store(in: &subs)

        // make a change
        let encoder = AutomergeEncoder(doc: createdDocHandle.doc)
        let model = ExampleStruct(title: "updated item", discussion: "editable text")
        try encoder.encode(model)
        // encoding writes into the document, which should initiate the change...
        
        await fulfillment(of: [documentChangePublisherExpectation], timeout: expectationTimeOut, enforceOrder: false)
        
        // and afterwards, their histories should be identical as well.
        XCTAssertEqual(createdDocHandle.doc.getHistory(), handle.doc.getHistory())
        // cleanup
        await websocketA.disconnect()
        await websocketB.disconnect()
    }
    
    func testIssue106_import_after_connect_eventual_sync() async throws {
        // code (nearly verbatim) from discussion in
        // https://github.com/automerge/automerge-repo-swift/issues/106
        
        // switching to local automerge-repo instance to keep dependencies local
        // let commonServerURL = URL(string: "wss://sync.automerge.org/")!
        let commonServerURL = try XCTUnwrap(URL(string: syncDestination))
        let commonDocumentId = DocumentId()
        let commonDocumentStartData = Automerge.Document().save()

        let repoA = Repo(sharePolicy: SharePolicy.agreeable)
        let websocketA = WebSocketProvider(.init(reconnectOnError: true, loggingAt: .tracing))
        await repoA.addNetworkAdapter(adapter: websocketA)
        try await websocketA.connect(to: commonServerURL)
        
        // create first document ('A') with an initial value,
        // then import it into RepoA
        
        let documentA = try Automerge.Document(commonDocumentStartData)
        try documentA.put(obj: .ROOT, key: "test", value: .String("some value"))
        _ = try await repoA.import(handle: .init(id: commonDocumentId, doc: documentA))

        let repoB = Repo(sharePolicy: SharePolicy.agreeable)
        let websocketB = WebSocketProvider(.init(reconnectOnError: true, loggingAt: .tracing))
        await repoB.addNetworkAdapter(adapter: websocketB)
        try await websocketB.connect(to: commonServerURL)
        
        // create a second document ('B') with an empty document and
        // import it into RepoB with the same ID
        
        let documentB = try Automerge.Document(commonDocumentStartData)
        _ = try await repoB.import(handle: .init(id: commonDocumentId, doc: documentB))

        var count = 0
        // this continues forever, heads never match
        while documentA.getHistory() != documentB.getHistory() {
        // while documentA.headsKey != documentB.headsKey {
            if count > 5 {
                XCTFail("Waited over 5 seconds for documents to sync")
            }
            count += 1
            //print("waiting for sync...")
            //print("document A: \(documentA.getHistory())")
            //print("document B: \(documentB.getHistory())")
            assert((try! documentA.get(obj: .ROOT, key: "test")) != nil)
            assert((try! documentB.get(obj: .ROOT, key: "test")) == nil)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        XCTAssertEqual(documentA.getHistory(), documentB.getHistory())
        //print("Sync success if reach this point!")
    }
}
