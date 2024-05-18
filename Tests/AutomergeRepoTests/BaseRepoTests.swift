import Automerge
@testable import AutomergeRepo
import AutomergeUtilities
import XCTest

final class BaseRepoTests: XCTestCase {
    var repo: Repo!

    override func setUp() async throws {
        repo = Repo(sharePolicy: SharePolicy.agreeable)
    }

    func testMostBasicRepoStartingPoints() async throws {
        let peers = await repo.peers()
        XCTAssertEqual(peers, [])

        let storageId = await repo.storageId()
        XCTAssertNil(storageId)

        let knownIds = await repo.documentIds()
        XCTAssertEqual(knownIds, [])
    }

    func testCreate() async throws {
        let newDoc = try await repo.create()
        XCTAssertNotNil(newDoc)
        let knownIds = await repo.documentIds()
        XCTAssertEqual(knownIds.count, 1)
    }

    func testCreateWithId() async throws {
        let myId = DocumentId()
        let handle = try await repo.create(id: myId)
        XCTAssertEqual(myId, handle.id)

        let knownIds = await repo.documentIds()
        XCTAssertEqual(knownIds.count, 1)
        XCTAssertEqual(knownIds[0], myId)
    }

    func testImportExistingDoc() async throws {
        let newHandleWithDoc = DocHandle(id: DocumentId(), doc: Document())
        let handle = try await repo.import(handle: newHandleWithDoc)
        let knownIds = await repo.documentIds()
        XCTAssertEqual(knownIds.count, 1)
        XCTAssertEqual(knownIds[0], handle.id)
    }

    func testFind() async throws {
        let myId = DocumentId()
        let handle = try await repo.create(id: myId)
        XCTAssertEqual(myId, handle.id)

        let foundDoc = try await repo.find(id: myId)
        XCTAssertEqual(foundDoc.doc.actor, handle.doc.actor)
    }

    func testFindFailed() async throws {
        do {
            let _ = try await repo.find(id: DocumentId())
            XCTFail()
        } catch {}
    }

    func testDelete() async throws {
        let myId = DocumentId()
        let _ = try await repo.create(id: myId)
        var knownIds = await repo.documentIds()
        XCTAssertEqual(knownIds.count, 1)

        try await repo.delete(id: myId)
        knownIds = await repo.documentIds()
        XCTAssertEqual(knownIds.count, 0)

        do {
            let _ = try await repo.find(id: DocumentId())
            XCTFail()
        } catch {}
    }

    func testClone() async throws {
        let myId = DocumentId()
        let handle = try await repo.create(id: myId)
        XCTAssertEqual(myId, handle.id)

        let clonedHandle = try await repo.clone(id: myId)
        XCTAssertNotEqual(handle.id, clonedHandle.id)
        XCTAssertNotEqual(handle.doc.actor, clonedHandle.doc.actor)

        let knownIds = await repo.documentIds()
        XCTAssertEqual(knownIds.count, 2)
    }

    // TBD:
    // - func storageIdForPeer(peerId) -> StorageId
    // - func subscribeToRemotes([StorageId])

    func testAsyncRepoSetup() async throws {
        let storage = InMemoryStorage()
        let repoA = Repo(sharePolicy: .agreeable, storage: storage)

        let storageId = await repoA.storageId()
        XCTAssertNotNil(storageId)
    }

    @AutomergeRepo
    func testSyncRepoSetup() throws {
        let storage = InMemoryStorage()
        let repoA = Repo(sharePolicy: .agreeable, storage: storage)

        let storageId = repoA.storageId()
        XCTAssertNotNil(storageId)
    }
}
