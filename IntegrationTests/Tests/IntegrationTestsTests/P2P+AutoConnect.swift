import Automerge
import AutomergeRepo
import AutomergeUtilities
import Foundation
import OSLog
import XCTest

extension RepoPeer2PeerIntegrationTests {
    func testAutoConnect() async throws {
        // set up repo (with a client-websocket)
        let repoAlice = Repo(sharePolicy: SharePolicy.agreeable)
        let p2pAlice = PeerToPeerProvider(.init(passcode: "1234"))
        await repoAlice.addNetworkAdapter(adapter: p2pAlice)
        try await p2pAlice.startListening(as: "Alice")

        // add the document to the Alice repo
        let handle: DocHandle = try await repoAlice.create(id: DocumentId())
        try addContent(handle.doc)

        let repoBob = Repo(sharePolicy: SharePolicy.agreeable)
        let p2pBob = PeerToPeerProvider(.init(passcode: "1234", autoconnect: true))
        await repoBob.addNetworkAdapter(adapter: p2pBob)
        try await p2pBob.startListening(as: "Bob")

        let aliceConnectionExpectation = expectation(description: "Repo 'Alice' sees a connection to Bob")
        let bobConnectionExpectation = expectation(description: "Repo 'Bob' sees a connection to Alice")

        let a_c = p2pAlice.connectionPublisher.receive(on: RunLoop.main).sink { connectList in
            // Logger.test.critical("TEST: CONNECT LIST FROM ALICE: \(String(describing: connectList))")
            if connectList.count == 1,
               connectList.contains(where: { connection in
                   connection.initiated == false &&
                       connection.peered == true &&
                       connection.peerId == repoBob.peerId
               })
            {
                aliceConnectionExpectation.fulfill()
            }
        }
        XCTAssertNotNil(a_c)

        let b_c = p2pBob.connectionPublisher.receive(on: RunLoop.main).sink { connectList in
            // Logger.test.critical("TEST: CONNECT LIST FROM BOB: \(String(describing: connectList))")
            if connectList.count == 1,
               connectList.contains(where: { connection in
                   connection.initiated == true &&
                       connection.peered == true &&
                       connection.peerId == repoAlice.peerId
               })
            {
                bobConnectionExpectation.fulfill()
            }
        }
        XCTAssertNotNil(b_c)

        await fulfillment(
            of: [aliceConnectionExpectation, bobConnectionExpectation],
            timeout: expectationTimeOut,
            enforceOrder: false
        )

        // MARK: cleanup and teardown

        await p2pAlice.disconnect()
        await p2pAlice.stopListening()
        await p2pBob.disconnect()
        await p2pBob.stopListening()
    }
}
