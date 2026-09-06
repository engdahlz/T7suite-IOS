// SPDX-License-Identifier: Apache-2.0
// New Swift implementation, 2026. Format references: T7Suite 0.1.59.0.
import Foundation

public enum T7Error: Error, Equatable, LocalizedError, Sendable {
    case invalid(String), unsupported(String), bounds, conflict, disconnected, timeout, busy
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return "Invalid data: \(message)"
        case .unsupported(let message): return "Not supported: \(message)"
        case .bounds: return "Address or length is outside the available data."
        case .conflict: return "Data changed since this edit was prepared."
        case .disconnected: return "The connection is closed."
        case .timeout: return "The operation timed out; reconnect before retrying."
        case .busy: return "A diagnostic transaction is already running."
        }
    }
}

public enum Bytes {
    public static func check(_ data: [UInt8], _ offset: Int, _ count: Int) throws {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { throw T7Error.bounds }
    }
    public static func uint(_ data: [UInt8], at offset: Int, width: Int, littleEndian: Bool = false) throws -> UInt32 {
        guard (1...4).contains(width) else { throw T7Error.invalid("integer width") }
        try check(data, offset, width)
        var value: UInt32 = 0
        if littleEndian {
            for index in stride(from: offset + width - 1, through: offset, by: -1) { value = (value << 8) | UInt32(data[index]) }
        } else {
            for index in offset..<offset + width { value = (value << 8) | UInt32(data[index]) }
        }
        return value
    }
    public static func encoded(_ value: UInt32, width: Int, littleEndian: Bool = false) throws -> [UInt8] {
        guard (1...4).contains(width), width == 4 || value < (UInt32(1) << (width * 8)) else { throw T7Error.invalid("integer overflow") }
        let data = (0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return littleEndian ? data.reversed() : data
    }
    public static func find(_ pattern: [UInt8], in data: [UInt8], from start: Int = 0, mask: [Bool]? = nil) -> Int? {
        guard !pattern.isEmpty, start >= 0, start <= data.count, pattern.count <= data.count - start,
              mask == nil || mask?.count == pattern.count else { return nil }
        for offset in start...(data.count - pattern.count) {
            var index = 0
            while index < pattern.count && (mask?[index] == false || data[offset + index] == pattern[index]) { index += 1 }
            if index == pattern.count { return offset }
        }
        return nil
    }
}

public struct FooterField: Sendable, Equatable {
    public let id: UInt8
    public let range: Range<Int>
    public let physicalBytes: [UInt8]
    public var text: String { String(bytes: physicalBytes.reversed(), encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? "" }
    public var integer: UInt32? {
        guard (1...4).contains(physicalBytes.count) else { return nil }
        // 9B/9C are physical big-endian; F2/FB/FE and most other numeric fields are reversed.
        return try? Bytes.uint(physicalBytes, at: 0, width: physicalBytes.count, littleEndian: id != 0x9B && id != 0x9C)
    }
    public var label: String {
        switch id {
        case 0x90: return "VIN"; case 0x91: return "Vehicle ID"; case 0x92: return "Immobilizer ID"
        case 0x93: return "Hardware"; case 0x94: return "Part number"; case 0x95: return "Software"
        case 0x97: return "Vehicle description"; case 0x98: return "Engine"; case 0x99: return "Test serial"
        case 0x9A: return "Modification date"; case 0x9B: return "Symbol table"; case 0x9C: return "SRAM offset"
        case 0xF2: return "F2 checksum"; case 0xFB: return "FB checksum"; case 0xFC: return "Flash end"
        case 0xFD: return "Checksum type"; case 0xFE: return "Firmware length"
        default: return String(format: "Field %02X", id)
        }
    }
}

public struct T7Footer: Sendable {
    public let fields: [FooterField]
    public init(bytes: [UInt8]) throws {
        guard bytes.count == T7Image.size else { throw T7Error.invalid("expected a 512 KiB T7 image") }
        var cursor = bytes.count
        var parsed: [FooterField] = []
        var seen = Set<UInt8>()
        let floor = bytes.count - 512
        var terminated = false
        while cursor >= floor + 2 {
            let length = Int(bytes[cursor - 1]), id = bytes[cursor - 2]
            if id == 0xFF { terminated = true; break }
            guard length > 0, length <= cursor - floor - 2, seen.insert(id).inserted else { throw T7Error.invalid("malformed or duplicate footer field") }
            let range = (cursor - 2 - length)..<(cursor - 2)
            parsed.append(FooterField(id: id, range: range, physicalBytes: Array(bytes[range])))
            cursor = range.lowerBound
        }
        guard terminated, !parsed.isEmpty else { throw T7Error.invalid("footer terminator not found") }
        fields = parsed
    }
    public subscript(_ id: UInt8) -> FooterField? { fields.first { $0.id == id } }
    public var firmwareLength: Int? { self[0xFE]?.integer.map(Int.init) }
    public var software: String { self[0x95]?.text ?? "Unknown" }
}

public struct T7Image: Sendable {
    public static let size = 0x80000
    public private(set) var bytes: [UInt8]
    public init(data: Data) throws {
        guard data.count == Self.size else { throw T7Error.invalid("expected 524288 bytes, received \(data.count)") }
        bytes = Array(data)
    }
    public var data: Data { Data(bytes) }
    public func footer() throws -> T7Footer { try T7Footer(bytes: bytes) }
    public func read(at address: Int, count: Int) throws -> [UInt8] {
        try Bytes.check(bytes, address, count)
        return Array(bytes[address..<address + count])
    }
    public mutating func replace(at address: Int, expected: [UInt8], with replacement: [UInt8]) throws {
        guard !expected.isEmpty, expected.count == replacement.count else { throw T7Error.invalid("length-changing edit") }
        guard try read(at: address, count: expected.count) == expected else { throw T7Error.conflict }
        bytes.replaceSubrange(address..<address + expected.count, with: replacement)
    }
}

public struct ChecksumValue: Sendable, Equatable {
    public let stored: UInt32
    public let calculated: UInt32
    public var matches: Bool { stored == calculated }
}
public struct ChecksumReport: Sendable {
    public let f2: ChecksumValue?
    public let fb: ChecksumValue
    public let firmware: ChecksumValue?
    public let firmwareIssue: String?
    public var isValid: Bool { (f2?.matches ?? true) && fb.matches && firmware?.matches == true }
}

public enum T7Checksums {
    private static let xorWords: [UInt32] = [0x81184224, 0x24421881, 0xC33C6666, 0x3CC3C3C3, 0x11882244, 0x18241824, 0x84211248, 0x12345678]
    public static func additive(_ data: [UInt8], range: Range<Int>) throws -> UInt32 {
        try Bytes.check(data, range.lowerBound, range.count)
        var sum: UInt32 = 0, p = range.lowerBound
        while p + 4 <= range.upperBound { sum = sum &+ (try Bytes.uint(data, at: p, width: 4)); p += 4 }
        // Legacy FB sums the trailing bytes in an 8-bit accumulator.
        var tail: UInt8 = 0
        while p < range.upperBound { tail = tail &+ data[p]; p += 1 }
        return sum &+ UInt32(tail)
    }
    public static func f2(_ data: [UInt8], length: Int) throws -> UInt32 {
        guard length > 0, length % 4 == 0 else { throw T7Error.unsupported("unaligned F2 length") }
        try Bytes.check(data, 0, length)
        var sum: UInt32 = 0
        for p in stride(from: 0, to: length, by: 4) { sum = sum &+ ((try Bytes.uint(data, at: p, width: 4)) ^ xorWords[(p / 4 + 1) % 8]) }
        return (sum ^ 0x40314081) &- 0x7FEFDFD0
    }
    struct Layout { let storage: Int; let regions: [Range<Int>] }
    static func layout(_ image: T7Image, footer: T7Footer) throws -> Layout {
        let b = image.bytes
        let pattern: [UInt8] = [0x48,0xE7,0,0x3C,0x24,0x7C,0,0xF0,0,0,0x26,0x7C,0,0,0,0,0x28,0x7C,0,0xF0,0,0,0x2A,0x7C]
        let mask = [true,true,true,true,true,true,true,true,false,false,true,true,true,false,false,false,true,true,true,true,false,false,true,true]
        guard let start = Bytes.find(pattern, in: b, mask: mask) else { throw T7Error.unsupported("firmware checksum routine signature") }
        var p = start + 22, base = 0, length: Int?, regions: [Range<Int>] = []
        let limit = min(b.count - 6, start + 4096)
        while p <= limit {
            let op = try Bytes.uint(b, at: p, width: 2); p += 2
            switch op {
            case 0x2A7C:
                let v = Int(try Bytes.uint(b, at: p, width: 4)); p += 4
                if v < 0xF00000 { base = v }
            case 0x4878:
                let v = Int(try Bytes.uint(b, at: p, width: 2)); p += 2
                guard v > 0, v < 0x8000, length == nil else { throw T7Error.unsupported("checksum region length") }
                length = v
            case 0x4879, 0x486D:
                let width = op == 0x4879 ? 4 : 2
                let address = Int(try Bytes.uint(b, at: p, width: width)) + (op == 0x486D ? base : 0); p += width
                guard let n = length, regions.count < 16 else { throw T7Error.unsupported("checksum region layout") }
                try Bytes.check(b, address, n)
                regions.append(address..<address + n); length = nil
            case 0xB0B9:
                var address = Int(try Bytes.uint(b, at: p, width: 4))
                if address >= b.count, let offset = footer[0x9C]?.integer { address -= Int(offset) }
                try Bytes.check(b, address, 4)
                guard !regions.isEmpty, length == nil, !regions.contains(where: { $0.overlaps(address..<address + 4) }) else { throw T7Error.unsupported("self-referential or incomplete checksum") }
                return Layout(storage: address, regions: regions)
            default: break
            }
        }
        throw T7Error.unsupported("firmware checksum terminator")
    }
    private static func length(_ footer: T7Footer) throws -> Int {
        guard let n = footer.firmwareLength, n > 0, n <= T7Image.size - 512, n % 4 == 0 else { throw T7Error.invalid("footer firmware length") }
        return n
    }
    public static func inspect(_ image: T7Image) throws -> ChecksumReport {
        let footer = try image.footer(), n = try length(footer)
        guard let fb = footer[0xFB]?.integer else { throw T7Error.invalid("missing FB checksum") }
        let c2 = try f2(image.bytes, length: n)
        // Original T7Suite treats an absent/zero F2 as disabled, not a pass by calculation.
        let f2Value = footer[0xF2]?.integer.flatMap { $0 == 0 ? nil : ChecksumValue(stored: $0, calculated: c2) }
        let fbValue = ChecksumValue(stored: fb, calculated: try additive(image.bytes, range: 0..<n))
        do {
            let l = try layout(image, footer: footer)
            var sum: UInt32 = 0
            for range in l.regions { sum = sum &+ (try additive(image.bytes, range: range)) }
            return ChecksumReport(f2: f2Value, fb: fbValue, firmware: ChecksumValue(stored: try Bytes.uint(image.bytes, at: l.storage, width: 4), calculated: sum), firmwareIssue: nil)
        } catch { return ChecksumReport(f2: f2Value, fb: fbValue, firmware: nil, firmwareIssue: error.localizedDescription) }
    }
    public static func repaired(_ image: T7Image) throws -> T7Image {
        let footer = try image.footer(), n = try length(footer), l = try layout(image, footer: footer)
        var copy = image, sum: UInt32 = 0
        for range in l.regions { sum = sum &+ (try additive(copy.bytes, range: range)) }
        try copy.replace(at: l.storage, expected: copy.read(at: l.storage, count: 4), with: Bytes.encoded(sum, width: 4))
        // Recalculate global checksums AFTER the firmware checksum changed.
        let c2 = try f2(copy.bytes, length: n), cb = try additive(copy.bytes, range: 0..<n)
        for (id, value): (UInt8, UInt32) in [(0xF2, c2), (0xFB, cb)] {
            guard let field = footer[id] else { if id == 0xF2 { continue }; throw T7Error.invalid("missing FB") }
            guard field.range.count == 4 else { throw T7Error.invalid("checksum field width") }
            if id == 0xF2 && field.integer == 0 { continue }
            try copy.replace(at: field.range.lowerBound, expected: field.physicalBytes, with: Bytes.encoded(value, width: 4, littleEndian: true))
        }
        guard try inspect(copy).isValid else { throw T7Error.invalid("checksum verification after repair") }
        return copy
    }
}
