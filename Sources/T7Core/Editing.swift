// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum CellEncoding: String, CaseIterable, Codable, Sendable {
    case u8, s8, u16, s16
    public var width: Int { self == .u8 || self == .s8 ? 1 : 2 }
    public var limits: ClosedRange<Int> {
        switch self { case .u8: return 0...255; case .s8: return -128...127; case .u16: return 0...65535; case .s16: return -32768...32767 }
    }
    public func decode(_ bytes: [UInt8]) throws -> [Int] {
        guard bytes.count % width == 0 else { throw T7Error.invalid("cell width does not divide map length") }
        return try stride(from: 0, to: bytes.count, by: width).map { p in
            let value = try Bytes.uint(bytes, at: p, width: width)
            switch self {
            case .s8: return Int(Int8(bitPattern: UInt8(value)))
            case .s16: return Int(Int16(bitPattern: UInt16(value)))
            default: return Int(value)
            }
        }
    }
    public func encode(_ values: [Int]) throws -> [UInt8] {
        try values.flatMap { value in
            guard limits.contains(value) else { throw T7Error.invalid("cell value outside \(limits)") }
            return try Bytes.encoded(UInt32(truncatingIfNeeded: value) & (width == 1 ? 0xFF : 0xFFFF), width: width)
        }
    }
}
public struct MapGrid: Sendable {
    public let encoding: CellEncoding
    public let columns: Int
    public private(set) var values: [Int]
    public var rows: Int { values.count / columns }
    public init(bytes: [UInt8], encoding: CellEncoding, columns: Int) throws {
        let values = try encoding.decode(bytes)
        guard !values.isEmpty, columns > 0, columns <= values.count, values.count % columns == 0 else { throw T7Error.invalid("map dimensions") }
        self.values = values; self.encoding = encoding; self.columns = columns
    }
    public mutating func set(_ value: Int, at index: Int) throws {
        guard values.indices.contains(index), encoding.limits.contains(value) else { throw T7Error.bounds }
        values[index] = value
    }
    public mutating func transform(indices: Set<Int>, multiply: Double = 1, add: Double = 0) throws {
        guard multiply.isFinite, add.isFinite else { throw T7Error.invalid("non-finite map transform") }
        var changed = values
        for index in indices {
            guard values.indices.contains(index) else { throw T7Error.bounds }
            let value = (Double(values[index]) * multiply + add).rounded()
            guard value.isFinite, value >= Double(encoding.limits.lowerBound), value <= Double(encoding.limits.upperBound) else { throw T7Error.invalid("map transform would overflow") }
            changed[index] = Int(value)
        }
        values = changed
    }
    public func bytes() throws -> [UInt8] { try encoding.encode(values) }
    public func csv() -> String {
        (0..<rows).map { row in values[row * columns..<(row + 1) * columns].map(String.init).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}
public struct BinaryPatch: Codable, Sendable, Equatable {
    public let address: Int
    public let before: [UInt8]
    public let after: [UInt8]
    public let reason: String
    public init(address: Int, before: [UInt8], after: [UInt8], reason: String) {
        self.address = address; self.before = before; self.after = after; self.reason = reason
    }
    public var reversed: Self { Self(address: address, before: after, after: before, reason: reason) }
}
public struct EditSession: Sendable {
    public let original: T7Image
    public private(set) var image: T7Image
    public private(set) var undoStack: [[BinaryPatch]] = []
    public private(set) var redoStack: [[BinaryPatch]] = []
    public init(image: T7Image) { original = image; self.image = image }
    public var isModified: Bool { image.bytes != original.bytes }
    public mutating func apply(_ patches: [BinaryPatch]) throws {
        guard !patches.isEmpty else { return }
        let ordered = patches.sorted { $0.address < $1.address }
        var end = -1
        for patch in ordered {
            try Bytes.check(image.bytes, patch.address, patch.before.count)
            guard patch.address >= end else { throw T7Error.invalid("overlapping patches") }
            end = patch.address + patch.before.count
        }
        var next = image
        for patch in patches { try next.replace(at: patch.address, expected: patch.before, with: patch.after) }
        image = next; undoStack.append(patches); redoStack.removeAll()
    }
    public mutating func undo() throws {
        guard let patches = undoStack.last else { return }
        var next = image
        for patch in patches.reversed() { let reverse = patch.reversed; try next.replace(at: reverse.address, expected: reverse.before, with: reverse.after) }
        image = next; undoStack.removeLast(); redoStack.append(patches)
    }
    public mutating func redo() throws {
        guard let patches = redoStack.last else { return }
        var next = image
        for patch in patches { try next.replace(at: patch.address, expected: patch.before, with: patch.after) }
        image = next; redoStack.removeLast(); undoStack.append(patches)
    }
    public func verifiedExport() throws -> Data { try T7Checksums.repaired(image).data }
}
public struct Difference: Identifiable, Sendable {
    public let range: Range<Int>
    public var id: Int { range.lowerBound }
}
public enum BinaryDiff {
    public static func compare(_ lhs: T7Image, _ rhs: T7Image) -> [Difference] {
        var ranges: [Difference] = [], start: Int?
        for i in lhs.bytes.indices {
            if lhs.bytes[i] != rhs.bytes[i] { if start == nil { start = i } }
            else if let first = start { ranges.append(Difference(range: first..<i)); start = nil }
        }
        if let first = start { ranges.append(Difference(range: first..<lhs.bytes.count)) }
        return ranges
    }
}
