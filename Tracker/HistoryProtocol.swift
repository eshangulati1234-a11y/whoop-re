import Foundation

/// Interoperability implementation based on OpenStrap's public protocol document.
/// No firmware, flash erase, read-pointer or optical commands are exposed.
enum HistoryProtocol {
    enum Command: UInt8 { case linkValid = 0x01, rawRealtime = 0x3f, realtimeHR = 0x03, optical = 0x6b, setClock = 0x0a, getClock = 0x0b, batteryLevel = 0x1a, hello = 0x23, name = 0x4c, range = 0x22, alarm = 0x43, history = 0x16, abort = 0x14, acknowledge = 0x17 }
    static func frame(_ inner: [UInt8]) -> [UInt8] {
        let padded = inner + Array(repeating: UInt8(0), count: (4 - inner.count % 4) % 4)
        let size = padded.count + 4
        let length = [UInt8(size & 255), UInt8(size >> 8)]
        let crc = FrameDecoder.crc32(padded)
        return [0xaa] + length + [FrameDecoder.crc8(length)] + padded + (0..<4).map { UInt8(truncatingIfNeeded: crc >> ($0 * 8)) }
    }
    static func command(_ command: Command, sequence: UInt8, body: [UInt8] = []) -> [UInt8] {
        frame([0x23, sequence, command.rawValue] + (body.isEmpty ? [command == .alarm ? 1 : 0] : body))
    }
    static func matchesResponse(_ frame: [UInt8], command: Command, sequence: UInt8?) -> Bool {
        guard let sequence, frame.count >= 5 else { return false }
        return frame[0] == 0x24 && frame[3] == sequence && frame[2] == command.rawValue
    }
    /// Battery percent from a GET_BATTERY_LEVEL reply: result 1, then a little-endian u16 in tenths of a percent.
    static func batteryResponse(_ frame: [UInt8]) -> Double? {
        guard frame.count >= 7, frame[0] == 0x24, frame[2] == Command.batteryLevel.rawValue, frame[4] == 1 else { return nil }
        let percent = Double(UInt16(frame[5]) | UInt16(frame[6]) << 8) / 10
        return (0...100).contains(percent) ? percent : nil
    }
    enum BandEvent: Equatable { case wristOn, wristOff, chargingOn, chargingOff }
    /// Wrist and charging events (packet 0x30, event id u16 at bytes 2-3, time u32 at 4-7) with their time.
    static func event(_ frame: [UInt8]) -> (event: BandEvent, date: Date)? {
        guard frame.count >= 8, frame[0] == 0x30 else { return nil }
        let kind: BandEvent
        switch UInt16(frame[2]) | UInt16(frame[3]) << 8 {
        case 9: kind = .wristOn
        case 10: kind = .wristOff
        case 7: kind = .chargingOn
        case 8: kind = .chargingOff
        default: return nil
        }
        let seconds = (0..<4).reduce(UInt32(0)) { $0 | UInt32(frame[4 + $1]) << (8 * $1) }
        return (kind, Date(timeIntervalSince1970: Double(seconds)))
    }
    static func clockBody(seconds: UInt32) -> [UInt8] {
        // whoop4-ble documents a trailing commit byte on WHOOP 4 firmware.
        (0..<4).map { UInt8(truncatingIfNeeded: seconds >> (8 * $0)) } + [1]
    }
    static func clockResponse(_ frame: [UInt8]) -> Date? {
        guard frame.count >= 9, frame[0] == 0x24, frame[2] == 0x0b, frame[4] == 1 else { return nil }
        let seconds = (0..<4).reduce(UInt32(0)) { $0 | UInt32(frame[5 + $1]) << (8 * $1) }
        return Date(timeIntervalSince1970: Double(seconds))
    }
    static func token(_ inner: [UInt8]) -> [UInt8]? {
        guard inner.count >= 21, inner[0] == 0x31, inner[2] == 2 else { return nil }
        return Array(inner[13..<21])
    }
    static func complete(_ inner: [UInt8]) -> Bool { inner.count >= 3 && inner[0] == 0x31 && inner[2] == 3 }
    static func rejectionReason(_ inner: [UInt8]) -> String? {
        guard inner.count == 96 else { return "unsupported record length" }
        guard inner[0] == 0x2f, inner[1] == 24 else { return "unsupported record type" }
        guard inner[17] > 0 else { return "no heart-rate reading" }
        let seconds = (0..<4).reduce(UInt32(0)) { $0 | UInt32(inner[7 + $1]) << (8 * $1) }
        guard seconds >= 1_577_836_800, Double(seconds) <= Date().timeIntervalSince1970 + 86400 else { return "device timestamp outside supported range" }
        return nil
    }
    static func sample(_ inner: [UInt8], device: String) -> Sample? {
        guard inner.count == 96, inner[0] == 0x2f, inner[1] == 24, inner[17] > 0 else { return nil }
        func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(inner[offset + $1]) << (8 * $1) } }
        let seconds = u32(7)
        // Quarantine implausible device clocks; retain the raw record for later decoding.
        guard seconds >= 1_577_836_800, Double(seconds) <= Date().timeIntervalSince1970 + 86400 else { return nil }
        return Sample(id: "\(device):\(seconds):\(u32(3))", date: Date(timeIntervalSince1970: Double(seconds)), bpm: Int(inner[17]))
    }

    /// Everything the 96-byte v24 history record carries that is verified against real data.
    /// Offsets are inner offsets. The "contact" byte (inner 51) and the words at 76 and 78 were checked against
    /// the phone's own records and are not decoded: contact takes values 0/69/70/197/198 with the same heart
    /// rate in each, and the other two are constant.
    struct Record: Equatable {
        var time: Int
        var counter: UInt32
        var bpm: Int
        /// Beat-to-beat intervals in ms. Sparse: about 37% of beat time is covered.
        var rr: [Int]
        /// Gravity vector in g, nil when its magnitude is implausible.
        var gravity: [Float]?
        var red: Int
        var ir: Int
        var skinRaw: Int
    }
    static func record(_ inner: [UInt8]) -> Record? {
        guard inner.count == 96, inner[0] == 0x2f, inner[1] == 24 else { return nil }
        func u16(_ o: Int) -> Int { Int(inner[o]) | Int(inner[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(inner[o + $1]) << (8 * $1) } }
        let seconds = u32(7)
        guard seconds >= 1_577_836_800, Double(seconds) <= Date().timeIntervalSince1970 + 86400 else { return nil }
        let count = Int(inner[18])
        guard count <= 4 else { return nil }
        let rr = (0..<count).map { u16(19 + 2 * $0) }.filter { (250...2500).contains($0) }
        let g = (0..<3).map { Float(bitPattern: u32(36 + 4 * $0)) }
        let magnitude = (g.map { $0 * $0 }.reduce(0, +)).squareRoot()
        let gravity: [Float]? = g.allSatisfy({ $0.isFinite }) && (0.5...1.5).contains(magnitude) ? g : nil
        return Record(time: Int(seconds), counter: u32(3), bpm: Int(inner[17]), rr: rr, gravity: gravity,
                      red: u16(64), ir: u16(66), skinRaw: u16(68))
    }
}
