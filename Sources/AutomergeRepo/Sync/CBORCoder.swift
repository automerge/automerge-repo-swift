import Foundation
public import PotentCBOR

/// A type that provides concurrency-safe access to a CBOR encoder and decoder.
public actor CBORCoder {
    /// A CBOR encoder
    public static let encoder = CBOREncoder()
    /// A CBOR decoder
    public static let decoder = CBORDecoder()
}
