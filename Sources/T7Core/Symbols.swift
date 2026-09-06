// SPDX-License-Identifier: Apache-2.0
// Swift rewrite of CommonSuite/TrionicSymbolDecompressor.cs and T7Suite/Trionic7File.cs.
// Changes: per-decoder state, bounded reads/output, strict failures, corrected Huffman rescaling,
// no guessed repair of damaged symbol addresses. Original work: TuningSuites contributors.
import Foundation

struct BitReader {
    let bytes: [UInt8]
    var position = 32
    mutating func read(_ width: Int) throws -> Int {
        guard width >= 0, width <= 24, position <= bytes.count * 8 - width else { throw T7Error.invalid("truncated compressed symbol data") }
        var value = 0
        for _ in 0..<width {
            value = (value << 1) | Int((bytes[position / 8] >> (7 - position % 8)) & 1)
            position += 1
        }
        return value
    }
}

struct AdaptiveHuffman {
    static let symbols = 314, nodes = 627, root = 626
    var weights = [Int](repeating: 0, count: 628)
    var parents = [Int](repeating: 0, count: 627)
    var leaves = [Int](repeating: 0, count: 314)
    var children = [Int](repeating: 0, count: 627)
    init() {
        for i in 0..<Self.symbols { weights[i] = 1; leaves[i] = i; children[i] = i + Self.nodes }
        var child = 0
        for i in Self.symbols..<Self.nodes {
            weights[i] = weights[child] + weights[child + 1]
            parents[child] = i; parents[child + 1] = i; children[i] = child; child += 2
        }
        weights[Self.nodes] = 0xFFFF
    }
    mutating func decode(_ bits: inout BitReader) throws -> Int {
        var node = children[Self.root]
        while node < Self.nodes { node = children[node + (try bits.read(1))] }
        let symbol = node - Self.nodes
        update(symbol)
        return symbol
    }
    mutating func update(_ symbol: Int) {
        if weights[Self.root] == 0x8000 { rebuild() }
        var node = leaves[symbol]
        repeat {
            weights[node] += 1
            var next = node + 1
            if weights[next] < weights[node] {
                repeat { next += 1 } while weights[next] < weights[node]
                next -= 1
                weights.swapAt(node, next)
                reparent(children[node], to: next); reparent(children[next], to: node)
                children.swapAt(node, next); node = next
            }
            node = parents[node]
        } while node != 0
    }
    mutating func reparent(_ child: Int, to parent: Int) {
        if child < Self.nodes { parents[child] = parent; parents[child + 1] = parent }
        else { leaves[child - Self.nodes] = parent }
    }
    mutating func rebuild() {
        // Keep LEAVES (>= nodes), not internal nodes. The legacy source explicitly marks
        // its opposite comparison as untested. This implements conventional LZHUF rescaling.
        var j = 0
        for i in 0..<Self.nodes where children[i] >= Self.nodes {
            weights[j] = (weights[i] + 1) / 2; children[j] = children[i]; j += 1
        }
        var child = 0
        for i in Self.symbols..<Self.nodes {
            let weight = weights[child] + weights[child + 1]
            var insertion = i
            while insertion > 0 && weights[insertion - 1] > weight { insertion -= 1 }
            if insertion < i {
                for k in stride(from: i, to: insertion, by: -1) { weights[k] = weights[k - 1]; children[k] = children[k - 1] }
            }
            weights[insertion] = weight; children[insertion] = child; child += 2
        }
        for i in 0..<Self.nodes { reparent(children[i], to: i) }
        parents[Self.root] = 0
    }
}

public enum T7SymbolCompression {
    public static func expand(_ input: [UInt8], maximumOutput: Int = 8 * 1024 * 1024) throws -> [UInt8] {
        let size = Int(try Bytes.uint(input, at: 0, width: 4, littleEndian: true))
        guard size > 0, size <= maximumOutput else { throw T7Error.invalid("symbol decompression size limit") }
        var reader = BitReader(bytes: input), tree = AdaptiveHuffman(), output: [UInt8] = []
        output.reserveCapacity(size)
        while output.count < size {
            let symbol = try tree.decode(&reader)
            if symbol < 256 { output.append(UInt8(symbol)); continue }
            let prefix = try reader.read(8)
            let high: Int, extra: Int
            switch prefix {
            case 0..<32: high = 0; extra = 1
            case 32..<80: high = (1 + (prefix - 32) / 16) * 64; extra = 2
            case 80..<144: high = (4 + (prefix - 80) / 8) * 64; extra = 3
            case 144..<192: high = (12 + (prefix - 144) / 4) * 64; extra = 4
            case 192..<240: high = (24 + (prefix - 192) / 2) * 64; extra = 5
            default: high = (48 + prefix - 240) * 64; extra = 6
            }
            let distance = (high | (((prefix << extra) | (try reader.read(extra))) & 63)) + 1
            let count = symbol - 253
            guard distance <= output.count, count <= size - output.count else { throw T7Error.invalid("invalid compressed back-reference") }
            for _ in 0..<count { output.append(output[output.count - distance]) }
        }
        return output
    }
    public static func names(_ input: [UInt8]) throws -> [String] {
        guard let text = String(bytes: try expand(input), encoding: .utf8) else { throw T7Error.invalid("symbol names are not UTF-8") }
        let names = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard names.count <= 20000, names.allSatisfy({ $0.utf8.count <= 512 }) else { throw T7Error.invalid("symbol name limits") }
        return names
    }
}

public struct T7Symbol: Identifiable, Sendable, Equatable {
    public let id: Int
    public var name: String
    public let address: UInt32
    public let length: Int
    public let type: UInt8
    public var flashAddress: Int?
    public var addressNote: String?
    public var category: String { name.components(separatedBy: ".").first ?? name }
    public var isCalibration: Bool {
        ["Cal.", "Cal1.", "Cal2.", "Cal3.", "Cal4."].contains(where: name.contains) || name.hasPrefix("X_Acc") || name.hasPrefix("DisplAdap.")
    }
    public var isEditable: Bool { isCalibration && flashAddress != nil && length > 0 && addressNote == nil }
}
public struct SymbolTable: Sendable {
    public let symbols: [T7Symbol]
    public let packed: Bool
    public let namesEmbedded: Bool
    public let sramOffset: UInt32?
    public let warnings: [String]
}

public enum T7Symbols {
    public static func parse(_ image: T7Image) throws -> SymbolTable {
        let b = image.bytes
        let signature: [UInt8] = [0,0,4,0,0,0,0,0,0,0,0,0,0x20,0]
        if let hit = Bytes.find(signature, in: b, from: 0x30000), hit >= 12 { return try packed(image, table: hit - 6) }
        return try unpacked(image)
    }
    private static func packed(_ image: T7Image, table: Int) throws -> SymbolTable {
        let b = image.bytes
        let offset = try Bytes.uint(b, at: table - 6, width: 4)
        let namesAddress = Int(try Bytes.uint(b, at: table, width: 4))
        let namesLength = Int(try Bytes.uint(b, at: table + 4, width: 2))
        var names: [String] = [], warnings: [String] = []
        if namesLength > 0x1000 && namesAddress > 0 && namesAddress < 0x70000 {
            names = try T7SymbolCompression.names(image.read(at: namesAddress, count: namesLength))
        } else { warnings.append("No embedded names. Import a software-matched symbol XML; do not infer names from another firmware.") }
        var p = table, result: [T7Symbol] = []
        while p + 10 <= b.count && result.count < 20000 {
            if b[p] == 0x53 && b[p + 1] == 0x43 { break }
            let number = result.count
            let address = try Bytes.uint(b, at: p, width: 4)
            let count = number == 0 ? 8 : Int(try Bytes.uint(b, at: p + 4, width: 2))
            let name = number < names.count ? names[number].trimmingCharacters(in: .whitespacesAndNewlines) : "Symbolnumber \(number)"
            let flash: Int? = address > 0 && address < UInt32(T7Image.size) && count <= T7Image.size - Int(address) ? Int(address) : nil
            result.append(T7Symbol(id: number, name: name, address: address, length: count, type: b[p + 8], flashAddress: flash))
            p += 10
        }
        guard p + 2 <= b.count, b[p] == 0x53, b[p + 1] == 0x43, !result.isEmpty else { throw T7Error.invalid("unterminated packed address table") }
        guard names.isEmpty || names.count == result.count || names.count == result.count - 1 else {
            throw T7Error.invalid("symbol name/address count mismatch: \(names.count)/\(result.count)")
        }
        if !names.isEmpty && names.count == result.count - 1 {
            // Observed in 116 supplied stock files; legacy also assigns only available names.
            // Preserve the last record and its index, but never invent a name or allow editing.
            result[result.count - 1].addressNote = "Trailing address record has no embedded name."
            warnings.append("One trailing symbol has no embedded name; retained read-only.")
        }
        let open = result.contains { ["BFuelCal.Map", "IgnNormCal.Map", "AirCtrlCal.map"].contains($0.name) && $0.address >= UInt32(T7Image.size) && (0x101..<0x400).contains($0.length) }
        if open {
            for i in result.indices where result[i].isCalibration && result[i].length < 0x400 && result[i].address > offset {
                let a = Int(result[i].address - offset)
                if result[i].flashAddress == nil && a > 0 && a < T7Image.size && result[i].length <= T7Image.size - a {
                    result[i].flashAddress = a; result[i].addressNote = "Open-software SRAM mapping: read-only until profile validation."
                }
            }
            warnings.append("Open-software relocation detected. Relocated maps remain read-only.")
        }
        return SymbolTable(symbols: result, packed: true, namesEmbedded: !names.isEmpty, sramOffset: offset, warnings: warnings)
    }
    private static func unpacked(_ image: T7Image) throws -> SymbolTable {
        let b = image.bytes
        var zeros = 0, start: Int?
        for p in b.indices {
            if b[p] == 0 { zeros += 1 }
            else { if zeros >= 15 && (32...126).contains(b[p]) { start = p; break }; zeros = 0 }
        }
        guard var p = start else { throw T7Error.unsupported("no recognized symbol table") }
        var names: [(Int, String)] = [], word: [UInt8] = [], wordStart = p
        while p < b.count && names.count < 20000 {
            let value = b[p]; p += 1
            if value == 2 { break }
            if value == 255 { if word.isEmpty { wordStart = p }; continue }
            if value == 0 {
                guard !word.isEmpty, let name = String(bytes: word, encoding: .ascii) else { throw T7Error.invalid("unpacked symbol name") }
                names.append((wordStart, name)); word = []; wordStart = p
            } else {
                guard (32...126).contains(value), word.count < 512 else { throw T7Error.invalid("unpacked symbol character") }
                if word.isEmpty { wordStart = p - 1 }; word.append(value)
            }
        }
        guard let first = names.first, p < b.count, b[p - 1] == 2 else { throw T7Error.invalid("unpacked symbol terminator") }
        let signature: [UInt8] = [0,0,0,0,0,0,0,0,0x20,0] + (try Bytes.encoded(UInt32(first.0), width: 4))
        guard let table = Bytes.find(signature, in: b) else { throw T7Error.unsupported("unpacked address table") }
        let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element.0, $0.offset) })
        var result = names.enumerated().map { T7Symbol(id: $0.offset, name: $0.element.1, address: 0, length: 0, type: 0, flashAddress: nil) }
        for row in 0..<names.count {
            let a = table + row * 14
            let address = try Bytes.uint(b, at: a, width: 4), count = Int(try Bytes.uint(b, at: a + 4, width: 2))
            let pointer = Int(try Bytes.uint(b, at: a + 10, width: 4))
            guard let i = index[pointer] else { throw T7Error.invalid("unpacked name pointer") }
            let direct = address > 0 && address < UInt32(T7Image.size) && count <= T7Image.size - Int(address)
            var symbol = T7Symbol(id: i, name: names[i].1, address: address, length: count, type: b[a + 8], flashAddress: direct ? Int(address) : nil)
            if address > 0xF00000 && symbol.isCalibration {
                let mapped = Int(address) - 0xEF02F0
                if mapped > 0 && mapped < T7Image.size && count <= T7Image.size - mapped {
                    symbol.flashAddress = mapped; symbol.addressNote = "Legacy unpacked relocation: read-only until profile validation."
                }
            }
            result[i] = symbol
        }
        return SymbolTable(symbols: result, packed: false, namesEmbedded: true, sramOffset: nil, warnings: ["Unpacked legacy address mappings require profile validation before editing."])
    }
}
