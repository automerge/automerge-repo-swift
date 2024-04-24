import Automerge
@testable import AutomergeRepo
import AutomergeUtilities
import OSLog
import XCTest

final class RepoPeer2PeerIntegrationTests: XCTestCase {
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
}
