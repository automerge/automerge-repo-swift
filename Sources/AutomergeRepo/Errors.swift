import Foundation

/// Describes errors from the repository and providers.
public enum Errors: Sendable {
    /// An error with the network provider.
    public struct NetworkProviderError: Sendable, LocalizedError {
        public var msg: String
        public var errorDescription: String? {
            "NetworkProviderError: \(msg)"
        }

        public init(msg: String) {
            self.msg = msg
        }
    }

    /// The sync protocol requested is unsupported.
    public struct UnsupportedProtocolError: Sendable, LocalizedError {
        public var msg: String
        public var errorDescription: String? {
            "Unsupported protocol requested: \(msg)"
        }

        public init(msg: String) {
            self.msg = msg
        }
    }

    /// The document in unavailable.
    public struct Unavailable: Sendable, LocalizedError {
        let id: DocumentId
        public var errorDescription: String? {
            "Unknown document Id: \(id)"
        }

        public init(id: DocumentId) {
            self.id = id
        }
    }

    /// The document is deleted.
    public struct DocDeleted: Sendable, LocalizedError {
        let id: DocumentId
        public var errorDescription: String? {
            "Document with Id: \(id) has been deleted."
        }

        public init(id: DocumentId) {
            self.id = id
        }
    }

    /// A request timed out before completion.
    public struct Timeout: Sendable, LocalizedError {
        public var errorDescription: String = "Task timed out before completion"
        public init(errorDescription: String? = nil) {
            if let errorDescription {
                self.errorDescription = errorDescription
            }
        }
    }

    /// The connection closed or does not exist.
    public struct ConnectionClosed: Sendable, LocalizedError {
        public var errorDescription: String = "The connection closed or is nil"
        public init(errorDescription: String? = nil) {
            if let errorDescription {
                self.errorDescription = errorDescription
            }
        }
    }

    /// The URL provided is invalid.
    public struct InvalidURL: Sendable, LocalizedError {
        public var urlString: String
        public var errorDescription: String? {
            "Invalid URL: \(urlString)"
        }

        public init(urlString: String) {
            self.urlString = urlString
        }
    }

    /// Received an unexpected message.
    public struct UnexpectedMsg: Sendable, LocalizedError {
        public var msg: String
        public var errorDescription: String? {
            "Received an unexpected message: \(msg)"
        }

        public init(msg: String) {
            self.msg = msg
        }
    }
    
    /// The ID of the document already exists within the repository
    public struct DuplicateID: Sendable, LocalizedError {
        public var id: DocumentId
        public var errorDescription: String? {
            "The ID of the document \(id) already exists within the repository."
        }

        public init(id: DocumentId) {
            self.id = id
        }
    }
}
