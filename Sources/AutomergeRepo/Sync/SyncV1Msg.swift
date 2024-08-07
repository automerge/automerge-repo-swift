//
//  SyncV1Msg.swift
//  MeetingNotes
//
//  Created by Joseph Heck on 1/24/24.
//

public import Foundation
internal import PotentCBOR

// Automerge Repo WebSocket sync details:
// https://github.com/automerge/automerge-repo/blob/main/packages/automerge-repo-network-websocket/README.md
// explicitly using a protocol version "1" here - make sure to specify (and verify?) that

// related source for the automerge-repo sync code:
// https://github.com/automerge/automerge-repo/blob/main/packages/automerge-repo-network-websocket/src/BrowserWebSocketClientAdapter.ts
// All the WebSocket messages are CBOR encoded and sent as data streams

/// Describes the possible V1 Automerge sync protocol messages.
public indirect enum SyncV1Msg: Sendable {
    // CDDL pre-amble
    // ; The base64 encoded bytes of a Peer ID
    // peer_id = str
    // ; The base64 encoded bytes of a Storage ID
    // storage_id = str
    // ; The possible protocol versions (currently always the string "1")
    // protocol_version = "1"
    // ; The bytes of an automerge sync message
    // sync_message = bstr
    // ; The base58check encoded bytes of a document ID
    // document_id = str

    /// The collection of value "type" strings for the V1 automerge-repo protocol.
    public enum MsgTypes: Sendable {
        public static let peer = "peer"
        public static let join = "join"
        public static let leave = "leave"
        public static let request = "request"
        public static let sync = "sync"
        public static let ephemeral = "ephemeral"
        public static let error = "error"
        public static let unavailable = "doc-unavailable"
        public static let remoteHeadsChanged = "remote-heads-changed"
        public static let remoteSubscriptionChange = "remote-subscription-change"
    }

    /// A request for a peer connection.
    case peer(PeerMsg)
    /// Acknowledging the request for a peer connection.
    case join(JoinMsg)
    /// A request to terminate a peer connection.
    case leave(LeaveMsg)
    /// An error response.
    case error(ErrorMsg)
    /// A request to find an Automerge document.
    case request(RequestMsg)
    /// A request to synchronize an Automerge document.
    case sync(SyncMsg)
    /// A response to a request for a document that indicates the document is not available.
    case unavailable(UnavailableMsg)
    /// An app-specific message for other network connected peers.
    case ephemeral(EphemeralMsg)
    // gossip additions
    /// A message that indicate an update to a subscription to remote document changes.
    case remoteSubscriptionChange(RemoteSubscriptionChangeMsg)
    /// A notification that updates occurred on a network peer.
    case remoteHeadsChanged(RemoteHeadsChangedMsg)

    // fall-through scenario - unknown message
    /// An unknown message.
    ///
    /// These are typically ignored, and are not guaranteed to be processed.
    case unknown(Data)

    /// Copies a message and returns an updated version with the targetId of message set to a specific target.
    /// - Parameter peer: The peer to set as the targetId for the message.
    /// - Returns: The updated message.
    public func setTarget(_ peer: PEER_ID) -> Self {
        switch self {
        case .peer(_), .join(_), .leave(_), .request(_), .sync(_), .unavailable(_), .error(_), .unknown:
            return self
        case let .ephemeral(msg):
            var copy = msg
            copy.targetId = peer
            return .ephemeral(copy)
        case let .remoteSubscriptionChange(msg):
            var copy = msg
            copy.targetId = peer
            return .remoteSubscriptionChange(copy)
        case let .remoteHeadsChanged(msg):
            var copy = msg
            copy.targetId = peer
            return .remoteHeadsChanged(copy)
        }
    }
}

extension SyncV1Msg: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case let .peer(interior_msg):
            interior_msg.debugDescription
        case let .join(interior_msg):
            interior_msg.debugDescription
        case let .leave(interior_msg):
            interior_msg.debugDescription
        case let .error(interior_msg):
            interior_msg.debugDescription
        case let .request(interior_msg):
            interior_msg.debugDescription
        case let .sync(interior_msg):
            interior_msg.debugDescription
        case let .unavailable(interior_msg):
            interior_msg.debugDescription
        case let .ephemeral(interior_msg):
            interior_msg.debugDescription
        case let .remoteSubscriptionChange(interior_msg):
            interior_msg.debugDescription
        case let .remoteHeadsChanged(interior_msg):
            interior_msg.debugDescription
        case let .unknown(data):
            "UNKNOWN[data: \(data.hexEncodedString(uppercase: false))]"
        }
    }
}
