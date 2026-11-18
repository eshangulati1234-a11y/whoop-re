import Foundation

/// Public OpenStrap framing reference; still requires validation on the target band.
struct FrameDecoder {
    private var buffer: [UInt8] = []
    mutating func append(_ bytes: [UInt8]) -> [[UInt8]] {
        buffer += bytes
        var frames: [[UInt8]] = []
        while buffer.count >= 4 {
            guard buffer[0] == 0xAA else { buffer.removeFirst(); continue }
            let size = Int(buffer[1]) | Int(buffer[2]) << 8
            guard Self.crc8(Array(buffer[1...2])) == buffer[3], size >= 4, size <= 16384, size % 4 == 0 else { buffer.removeFirst(); continue }
            guard buffer.count >= size + 4 else { break }
            let payload = Array(buffer[4..<size])
            let checksum = (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[size + $1]) << (8 * $1) }
            if Self.crc32(payload) == checksum { frames.append(payload); buffer.removeFirst(size + 4) }
            else { buffer.removeFirst() }
        }
        return frames
    }
    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes { crc ^= byte; for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc &<< 1) ^ 0x07 : crc &<< 1 } }
        return crc
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 } }
        return ~crc
    }
}
