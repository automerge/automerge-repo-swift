import Base58Swift
public import struct Foundation.Data
public import struct Foundation.UUID

/// A unique identifier for an Automerge document.
public struct DocumentId: Sendable, Hashable, Comparable, Identifiable {
    /// A bs58 encoded string that represents the identifier
    public let id: String
    let data: Data

    /// Creates a random document identifier.
    public init() {
        let uuid = UUID()
        data = uuid.data
        id = uuid.bs58String
    }

    /// Creates a document identifier from a UUID v4.
    /// - Parameter id: the v4 UUID to use as a document identifier.
    public init(_ id: UUID) {
        self.data = id.data
        self.id = id.bs58String
    }

    /// Creates a document identifier or returns nil if the optional string you provide is not a valid DocumentID.
    /// - Parameter id: The string to use as a document identifier.
    public init?(_ id: String?) {
        guard let id else {
            return nil
        }
        guard let uint_array = Base58.base58CheckDecode(id) else {
            return nil
        }
        if uint_array.count != 16 {
            return nil
        }
        self.id = id
        self.data = Data(uint_array)
    }

    /// Creates a document identifier or returns nil if the string you provide is not a valid DocumentID.
    /// - Parameter id: The string to use as a document identifier.
    public init?(_ id: String) {
        guard let uint_array = Base58.base58CheckDecode(id) else {
            return nil
        }
        if uint_array.count != 16 {
            return nil
        }
        self.id = id
        self.data = Data(uint_array)
    }

    // Comparable conformance
    public static func < (lhs: DocumentId, rhs: DocumentId) -> Bool {
        lhs.id < rhs.id
    }
}

extension DocumentId: Codable {}

extension DocumentId: CustomStringConvertible {
    /// The string representation of the Document identifier.
    public var description: String {
        id
    }
}
