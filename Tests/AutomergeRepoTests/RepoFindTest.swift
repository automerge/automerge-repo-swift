import Automerge
@testable import AutomergeRepo
import AutomergeUtilities
import XCTest

final class RepoFindTest: XCTestCase {
    func testRepoFindWithoutNetworkingActive() async throws {
        // https://github.com/automerge/automerge-repo-swift/issues/84
        let repo = Repo(sharePolicy: SharePolicy.agreeable)
        await repo.setLogLevel(.resolver, to: .tracing)
        await repo.setLogLevel(.network, to: .tracing)
        let websocket = WebSocketProvider(.init(reconnectOnError: false, loggingAt: .tracing))
        await repo.addNetworkAdapter(adapter: websocket)

        let unavailableExpectation =
            expectation(description: "Find should throw an Unavailable error if no peers are available to request from")
        Task {
            do {
                let handle = try await repo.find(id: DocumentId()) // never completes, never errors
                print(handle)
            } catch {
                unavailableExpectation.fulfill()
            }
        }
        await fulfillment(of: [unavailableExpectation], timeout: 5)
    }
}
