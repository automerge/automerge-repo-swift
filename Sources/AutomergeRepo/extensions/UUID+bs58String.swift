import Base58Swift
public import struct Foundation.Data
public import struct Foundation.UUID

public extension UUID {
    /// The contents of the UUID as data.
    var data: Data {
        var byteblob = Data(count: 16)
        byteblob[0] = uuid.0
        byteblob[1] = uuid.1
        byteblob[2] = uuid.2
        byteblob[3] = uuid.3
        byteblob[4] = uuid.4
        byteblob[5] = uuid.5
        byteblob[6] = uuid.6
        byteblob[7] = uuid.7
        byteblob[8] = uuid.8
        byteblob[9] = uuid.9
        byteblob[10] = uuid.10
        byteblob[11] = uuid.11
        byteblob[12] = uuid.12
        byteblob[13] = uuid.13
        byteblob[14] = uuid.14
        byteblob[15] = uuid.15
        return byteblob
    }

    /// The contents of UUID as a BS58 encoded string.
    var bs58String: String {
        Base58.base58CheckEncode(data.bytes)
    }
}
