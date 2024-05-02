import struct Foundation.Data

// loose adaptation from automerge-repo storage interface
// https://github.com/automerge/automerge-repo/blob/main/packages/automerge-repo/src/storage/StorageAdapter.ts
/// A type that provides an interface for persisting the changes to Automerge documents.
@AutomergeRepo
public protocol StorageProvider: Sendable {
    /// The identifier for the persistent storage location.
    nonisolated var id: STORAGE_ID { get }

    /// Return the data for an Automerge document
    /// - Parameter id: The ID of the document
    /// - Returns: The combined data that can be loaded into a Document
    func load(id: DocumentId) async throws -> Data?

    /// Save the data you provide as the ID you provide.
    /// - Parameters:
    ///   - id: The ID of the document
    ///   - data: The data from the Document
    func save(id: DocumentId, data: Data) async throws

    /// Remove the stored data for the ID you provide
    /// - Parameter id: The ID of the document
    func remove(id: DocumentId) async throws

    // MARK: Incremental Load Support

    /// Stores incremental data updates in parallel for the document and prefix you provide.
    /// - Parameters:
    ///   - id: The ID of the document
    ///   - prefix: The identifier for the parallel set of data to store.
    ///   - data: The combined incremental updates from the document
    func addToRange(id: DocumentId, prefix: String, data: Data) async throws

    /// Retrieve the incremental data updates for the document and prefix you provide.
    /// - Parameters:
    ///   - id: The ID of the document
    ///   - prefix: The identifier for the parallel set of data to store.
    /// - Returns: The combined incremental updates from the document
    func loadRange(id: DocumentId, prefix: String) async throws -> [Data]

    /// Removes the list of data you provide for the document and prefix you provide.
    /// - Parameters:
    ///   - id: The ID of the document
    ///   - prefix: The identifier for the parallel set of data to store.
    ///   - data: The list of incremental updates to remove.
    func removeRange(id: DocumentId, prefix: String, data: [Data]) async throws
}
