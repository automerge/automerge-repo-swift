import Foundation

public extension SyncV1Msg {
    enum Errors: Sendable {
        public struct Timeout: Sendable, LocalizedError {
            public var errorDescription: String = "Task timed out before completion"
            public init(errorDescription: String? = nil) {
                if let errorDescription {
                    self.errorDescription = errorDescription
                }
            }
        }

        public struct SyncComplete: Sendable, LocalizedError {
            public var errorDescription: String = "The synchronization process is complete"
            public init(errorDescription: String? = nil) {
                if let errorDescription {
                    self.errorDescription = errorDescription
                }
            }
        }

        public struct ConnectionClosed: Sendable, LocalizedError {
            public var errorDescription: String = "The websocket task was closed and/or nil"
            public init(errorDescription: String? = nil) {
                if let errorDescription {
                    self.errorDescription = errorDescription
                }
            }
        }

        public struct InvalidURL: Sendable, LocalizedError {
            public var urlString: String
            public var errorDescription: String? {
                "Invalid URL: \(urlString)"
            }

            public init(urlString: String) {
                self.urlString = urlString
            }
        }

        public struct UnexpectedMsg: Sendable, LocalizedError {
            public var msg: String
            public var errorDescription: String? {
                "Received an unexpected message: \(msg)"
            }

            public init(msg: String) {
                self.msg = msg
            }
        }

        public struct DocumentUnavailable: Sendable, LocalizedError {
            public var errorDescription: String = "The requested document isn't available"
        }
    }
}
