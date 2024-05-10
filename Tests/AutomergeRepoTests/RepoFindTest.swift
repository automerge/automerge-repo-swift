import Automerge
@testable import AutomergeRepo
import AutomergeUtilities
import XCTest

final class RepoFindTest: XCTestCase {
    func testRepoFindWithoutNetworkingActive() async throws {
        let repo = Repo(sharePolicy: SharePolicy.agreeable)
        let websocket = WebSocketProvider(.init(reconnectOnError: false, loggingAt: .tracing))
        await repo.addNetworkAdapter(adapter: websocket)

        let unavailableExpectation = expectation(description: "find should throw an Unavailable error")
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
