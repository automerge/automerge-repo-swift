@testable import AutomergeRepo
import Base58Swift
import XCTest

final class DocumentIdTests: XCTestCase {
    func testInvalidDocumentIdString() async throws {
        XCTAssertNil(DocumentId("some random string"))
    }

    func testDocumentId() async throws {
        let someUUID = UUID()
        let id = DocumentId(someUUID)
        XCTAssertEqual(id.description, someUUID.bs58String)
    }

    func testDocumentIdFromString() async throws {
        let someUUID = UUID()
        let bs58String = someUUID.bs58String
        let id = DocumentId(bs58String)
        XCTAssertEqual(id?.description, bs58String)

        let invalidOptionalString: String? = "SomeRandomNonBS58String"
        XCTAssertNil(DocumentId(invalidOptionalString))

        let invalidString = "SomeRandomNonBS58String"
        XCTAssertNil(DocumentId(invalidString))

        let optionalString: String? = bs58String
        XCTAssertEqual(DocumentId(optionalString)?.description, bs58String)

        XCTAssertNil(DocumentId(nil))
    }

    func testInvalidTooMuchDataDocumentId() async throws {
        let tooBig = [UInt8](UUID().data + UUID().data)
        let bs58StringFromData = Base58.base58CheckEncode(tooBig)
        let tooLargeOptionalString: String? = bs58StringFromData
        XCTAssertNil(DocumentId(bs58StringFromData))
        XCTAssertNil(DocumentId(tooLargeOptionalString))

        let optionalString: String? = bs58StringFromData
        XCTAssertNil(DocumentId(optionalString))
    }

    func testComparisonOnData() async throws {
        let first = DocumentId()
        let second = DocumentId()
        let compareFirstAndSecond = first < second
        let compareFirstAndSecondDescription = first.description < second.description
        XCTAssertEqual(compareFirstAndSecond, compareFirstAndSecondDescription)
    }

    func testStringConversionDocumentId() async throws {
        // roughly 2 in 1000 are failing the conversion down and back
        for i in 1 ... 1000 {
            let new = DocumentId()
            let stringOfDocumentId = new.id
            let converted = DocumentId(stringOfDocumentId)
            XCTAssertNotNil(converted, "id: \(new) [\(new.data.hexEncodedString())] doesn't back convert (try #\(i))")
        }
    }

    func testExploreFailedStringBackconvert() async throws {
        // illustrates a specific example from https://github.com/automerge/automerge-repo-swift/issues/108
        let data = "00cf851bc4f4441d86d127c26774145e".data(using: .hexadecimal)
        let output = Base58.base58CheckEncode([UInt8](data!))
        XCTAssertEqual(output, "1ezULPhgshBPYi4H2MTBoMKwc3S")
        let checkDecode = Base58.base58CheckDecode(output)
        XCTAssertNotNil(checkDecode)
    }
}
