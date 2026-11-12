import Foundation

/// Writes an uncompressed ("stored") zip, enough to build Yomitan dictionaries in tests
/// without the `zip` tool (unavailable in the simulator).
public struct ZipWriter {
    private var entries: [(name: String, data: Data)] = []

    public init() {}

    public mutating func add(_ name: String, _ data: Data) {
        entries.append((name, data))
    }

    public mutating func add(_ name: String, json: Any) throws {
        add(name, try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }

    public func data() -> Data {
        var body = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let offset = UInt32(body.count)
            body.append(le32(0x04034b50))
            body.append(le16(20)); body.append(le16(0x0800)); body.append(le16(0))  // version, UTF-8 names, stored
            body.append(le16(0)); body.append(le16(0x21))                           // time, date (1980-01-01)
            body.append(le32(crc)); body.append(le32(UInt32(entry.data.count))); body.append(le32(UInt32(entry.data.count)))
            body.append(le16(UInt16(name.count))); body.append(le16(0))
            body.append(name); body.append(entry.data)

            directory.append(le32(0x02014b50))
            directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(0x0800)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0x21))
            directory.append(le32(crc)); directory.append(le32(UInt32(entry.data.count))); directory.append(le32(UInt32(entry.data.count)))
            directory.append(le16(UInt16(name.count))); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0)); directory.append(le32(offset))
            directory.append(name)
        }
        var end = Data()
        end.append(le32(0x06054b50)); end.append(le16(0)); end.append(le16(0))
        end.append(le16(UInt16(entries.count))); end.append(le16(UInt16(entries.count)))
        end.append(le32(UInt32(directory.count))); end.append(le32(UInt32(body.count))); end.append(le16(0))
        return body + directory + end
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
