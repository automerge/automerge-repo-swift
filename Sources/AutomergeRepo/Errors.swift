import Foundation

enum Errors: Sendable {
    public struct NetworkProviderError: Sendable, LocalizedError {
        public var msg: String
        public var errorDescription: String? {
            "NetworkProviderError: \(msg)"
        }

        public init(msg: String) {
            self.msg = msg
        }
    }

    public struct UnsupportedProtocolError: Sendable, LocalizedError {
        public var msg: String
        public var errorDescription: String? {
            "Unsupported protocol requested: \(msg)"
        }

        public init(msg: String) {
            self.msg = msg
        }
    }

    public struct Unavailable: Sendable, LocalizedError {
        let id: DocumentId
        public var errorDescription: String? {
            "Unknown document Id: \(id)"
        }

        public init(id: DocumentId) {
            self.id = id
        }
    }

    public struct DocDeleted: Sendable, LocalizedError {
        let id: DocumentId
        public var errorDescription: String? {
            "Document with Id: \(id) has been deleted."
        }

        public init(id: DocumentId) {
            self.id = id
        }
    }

    public struct DocUnavailable: Sendable, LocalizedError {
        let id: DocumentId
        public var errorDescription: String? {
            "Document with Id: \(id) is unavailable."
        }

        public init(id: DocumentId) {
            self.id = id
        }
    }

    public struct BigBadaBoom: Sendable, LocalizedError {
        let msg: String
        public var errorDescription: String? {
            "Something went quite wrong: \(msg)."
        }

        public init(msg: String) {
            self.msg = msg
        }
    }
}
