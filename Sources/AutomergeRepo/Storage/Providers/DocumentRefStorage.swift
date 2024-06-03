import struct Foundation.Data
import struct Foundation.UUID

// Starting points from the Operating System (SwiftUI):
// - ReferenceFileDocument (https://developer.apple.com/documentation/swiftui/referencefiledocument)
//   - stores updates by calling `snapshot(contenttype:)` (https://developer.apple.com/documentation/swiftui/referencefiledocument/snapshot(contenttype:))
//   - handles the resulting content with `filewrapper(snapshot:configuration:)` https://developer.apple.com/documentation/swiftui/referencefiledocument/filewrapper(snapshot:configuration:)
//     asking you to provide a FileWrapper that it can use to shove the data into place
//   - Reading a new document hands off a configuration with a FileWrapper embedded in it (https://developer.apple.com/documentation/swiftui/filedocumentreadconfiguration)
//
//   - FileWrapper (https://developer.apple.com/documentation/foundation/filewrapper)


// AppKit uses NSDocument: https://developer.apple.com/documentation/appkit/nsdocument
// - note: NSDocument is @MainActor, returned from NSDocumentController
// - The developer is expected to subclass and override NSDocument to provide the expected functionality
//

// UIKit uses UIDocument: https://developer.apple.com/documentation/uikit/uidocument
// - similar in subclass-and-override to NSDocument, but with a more limited set of options (evolved version?)
// that focuses on `load()` and `save()` overrides for data in and out, reaching down to FileWrapper in some
// instances (see https://developer.apple.com/documentation/uikit/uidocument#1658531)
/// An ??? storage provider.
@AutomergeRepo
public final class DocumentRefStorage: StorageProvider {
    public nonisolated let id: STORAGE_ID = UUID().uuidString

    var _storage: [DocumentId: Data] = [:]
    var _incrementalChunks: [CombinedKey: [Data]] = [:]

    public nonisolated init() {}

    public struct CombinedKey: Hashable, Comparable {
        public static func < (lhs: DocumentRefStorage.CombinedKey, rhs: DocumentRefStorage.CombinedKey) -> Bool {
            if lhs.prefix == rhs.prefix {
                return lhs.id < rhs.id
            }
            return lhs.prefix < rhs.prefix
        }

        public let id: DocumentId
        public let prefix: String
    }

    public func load(id: DocumentId) async -> Data? {
        _storage[id]
    }

    public func save(id: DocumentId, data: Data) async {
        _storage[id] = data
    }

    public func remove(id: DocumentId) async {
        _storage.removeValue(forKey: id)
    }

    // MARK: Incremental Load Support

    public func addToRange(id: DocumentId, prefix: String, data: Data) async {
        var dataArray: [Data] = _incrementalChunks[CombinedKey(id: id, prefix: prefix)] ?? []
        dataArray.append(data)
        _incrementalChunks[CombinedKey(id: id, prefix: prefix)] = dataArray
    }

    public func loadRange(id: DocumentId, prefix: String) async -> [Data] {
        _incrementalChunks[CombinedKey(id: id, prefix: prefix)] ?? []
    }

    public func removeRange(id: DocumentId, prefix: String, data: [Data]) async {
        var chunksForKey: [Data] = _incrementalChunks[CombinedKey(id: id, prefix: prefix)] ?? []
        for d in data {
            if let indexToRemove = chunksForKey.firstIndex(of: d) {
                chunksForKey.remove(at: indexToRemove)
            }
        }
        _incrementalChunks[CombinedKey(id: id, prefix: prefix)] = chunksForKey
    }

    // MARK: Testing Spies/Support

    public func storageKeys() -> [DocumentId] {
        _storage.keys.sorted()
    }

    public func incrementalKeys() -> [CombinedKey] {
        _incrementalChunks.keys.sorted()
    }
}
