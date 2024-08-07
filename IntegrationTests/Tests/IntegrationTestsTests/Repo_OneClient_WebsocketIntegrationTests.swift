import Automerge
import AutomergeRepo
import AutomergeUtilities
import OSLog
import XCTest

// NOTE(heckj): This integration test expects that you have a websocket server with the
// Automerge-repo sync protocol running at localhost:3030. If you're testing from the local
// repository, run the `./scripts/interop.sh` script to start up a local instance to
// respond.

final class Repo_OneClient_WebsocketIntegrationTests: XCTestCase {
    private static let subsystem = Bundle.main.bundleIdentifier!

    static let test = Logger(subsystem: subsystem, category: "WebSocketSyncIntegrationTests")
    let syncDestination = "ws://localhost:3030/"
    // Switch to the following line to run a test against the public hosted automerge-repo instance
//    let syncDestination = "wss://sync.automerge.org/"

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

    func testSyncAndFind() async throws {
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

        // set up repo (with a client-websocket)
        let repo = Repo(sharePolicy: SharePolicy.agreeable)
        let websocket = WebSocketProvider()
        await repo.addNetworkAdapter(adapter: websocket)

        // add the document to the repo
        let handle: DocHandle = try await repo.create(id: DocumentId())

        // initial setup and encoding of Automerge doc to sync it
        let encoder = AutomergeEncoder(doc: handle.doc)
        let model = ExampleStruct(title: "new item", discussion: "editable text")
        try encoder.encode(model)

        let url = try XCTUnwrap(URL(string: syncDestination))
        try await websocket.connect(to: url)

        // With the websocket protocol, we don't get confirmation of a sync being complete -
        // if the other side has everything and nothing new, they just won't send a response
        // back. In that case, we don't get any further responses - but we don't _know_ that
        // it's complete. In an initial sync there will always be at least one response, but
        // we can't quite count on this always being an initial sync... so I'm shimming in a
        // short "wait" here to leave the background tasks that receive WebSocket messages
        // running to catch any updates, and hoping that'll be enough time to complete it.
        try await Task.sleep(for: .seconds(5))
        await websocket.disconnect()

        // Create a second, empty repo that doesn't have the document and request it

        // set up repo (with a client-websocket)
        let repoTwo = Repo(sharePolicy: SharePolicy.agreeable)
        let websocketTwo = WebSocketProvider()
        await repoTwo.addNetworkAdapter(adapter: websocketTwo)

        // connect the repo to the external automerge-repo
        try await websocketTwo.connect(to: url)

        let foundDocHandle = try await repoTwo.find(id: handle.id)
        XCTAssertEqual(foundDocHandle.id, handle.id)
        XCTAssertTrue(foundDocHandle.doc.equivalentContents(handle.doc))
    }

    func testFindWithRandomId() async throws {
        let repo = Repo(sharePolicy: SharePolicy.agreeable)
        let websocket = WebSocketProvider(.init(reconnectOnError: false, loggingAt: .tracing))
        await repo.addNetworkAdapter(adapter: websocket)

        let url = try XCTUnwrap(URL(string: syncDestination))
        try await websocket.connect(to: url)

        let randomId = DocumentId()
        do {
            let _ = try await repo.find(id: randomId)
            XCTFail("Repo shouldn't return a new, empty document for a random Document ID")
        } catch let error as Errors.Unavailable {
            XCTAssertEqual(error.id, randomId)
        } catch {
            XCTFail("Unknown error returned")
        }
    }
}
