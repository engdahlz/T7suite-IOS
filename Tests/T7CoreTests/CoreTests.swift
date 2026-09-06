import XCTest
@testable import T7Core

final class CoreTests: XCTestCase {
    func syntheticImage() throws -> T7Image {
        var b = [UInt8](repeating: 0xFF, count: T7Image.size)
        let routine: [UInt8] = [0x48,0xE7,0,0x3C,0x24,0x7C,0,0xF0,0,0,0x26,0x7C,0,0,0,0,0x28,0x7C,0,0xF0,0,0,0x2A,0x7C,
                               0,0,0,0, 0x48,0x78,0,16, 0x48,0x79,0,0,2,0, 0xB0,0xB9,0,0,3,0]
        b.replaceSubrange(0x100..<0x100 + routine.count, with: routine)
        b.replaceSubrange(0x200..<0x210, with: Array(0..<16))
        var cursor = b.count
        func field(_ id: UInt8, _ bytes: [UInt8]) {
            let part = bytes + [id, UInt8(bytes.count)]
            b.replaceSubrange(cursor - part.count..<cursor, with: part); cursor -= part.count
        }
        field(0x95, Array("TEST.001".utf8.reversed()))
        field(0x9C, [0,0xEF,0,0]); field(0xFE, [0,4,0,0]); field(0xF2, [1,0,0,0]); field(0xFB, [0,0,0,0])
        return try T7Image(data: Data(b))
    }
    func testBinarySize() throws {
        XCTAssertThrowsError(try T7Image(data: Data()))
        XCTAssertThrowsError(try T7Image(data: Data(repeating: 0, count: T7Image.size + 1)))
    }
    func testEndian() throws {
        XCTAssertEqual(try Bytes.uint([0x12,0x34,0x56,0x78], at: 0, width: 4), 0x12345678)
        XCTAssertEqual(try Bytes.uint([0x12,0x34], at: 0, width: 2, littleEndian: true), 0x3412)
        XCTAssertEqual(try Bytes.encoded(0x1234, width: 2, littleEndian: true), [0x34,0x12])
        XCTAssertThrowsError(try Bytes.encoded(256, width: 1))
        XCTAssertThrowsError(try Bytes.uint([], at: Int.max, width: 4))
        XCTAssertThrowsError(try Bytes.uint([1], at: -1, width: 1))
    }
    func testMaskedPatternOverlap() {
        XCTAssertEqual(Bytes.find([1,1,2], in: [1,1,1,2]), 1)
        XCTAssertEqual(Bytes.find([1,7,2], in: [1,5,2], mask: [true,false,true]), 0)
        XCTAssertNil(Bytes.find([1], in: [], from: 1))
    }
    func testFooter() throws {
        let footer = try syntheticImage().footer()
        XCTAssertEqual(footer.software, "TEST.001")
        XCTAssertEqual(footer.firmwareLength, 1024)
        XCTAssertEqual(footer[0x9C]?.integer, 0xEF0000)
        XCTAssertEqual(footer[0xF2]?.integer, 1)
    }
    func testMalformedFooter() throws {
        var image = try syntheticImage()
        try image.replace(at: T7Image.size - 1, expected: [8], with: [0])
        XCTAssertThrowsError(try image.footer())
        XCTAssertThrowsError(try T7Footer(bytes: [UInt8](repeating: 0xFF, count: T7Image.size)))
    }
    func testAdditiveWrapAndByteTail() throws {
        XCTAssertEqual(try T7Checksums.additive([255,255,255,255,0,0,0,1], range: 0..<8), 0)
        XCTAssertEqual(try T7Checksums.additive([0,0,0,1,255,2], range: 0..<6), 2)
    }
    func testF2KnownVector() throws {
        // Independently calculated from the published XOR constants and the index-1 start.
        let expected = (UInt32(0x24421881) ^ UInt32(0x40314081)) &- UInt32(0x7FEFDFD0)
        XCTAssertEqual(try T7Checksums.f2([0,0,0,0], length: 4), expected)
        XCTAssertThrowsError(try T7Checksums.f2([0,0,0], length: 3))
    }
    func testAllChecksumRepairAndIdempotence() throws {
        let image = try syntheticImage()
        XCTAssertFalse(try T7Checksums.inspect(image).isValid)
        let fixed = try T7Checksums.repaired(image)
        XCTAssertTrue(try T7Checksums.inspect(fixed).isValid)
        XCTAssertEqual(try T7Checksums.repaired(fixed).bytes, fixed.bytes)
        XCTAssertNotEqual(image.bytes, fixed.bytes)
    }
    func testEditRechecksumsGlobalAfterFirmwareChange() throws {
        var image = try T7Checksums.repaired(syntheticImage())
        try image.replace(at: 0x200, expected: [0], with: [100])
        let report = try T7Checksums.inspect(image)
        XCTAssertFalse(report.firmware!.matches)
        let repaired = try T7Checksums.repaired(image)
        XCTAssertTrue(try T7Checksums.inspect(repaired).isValid)
        XCTAssertEqual(repaired.bytes[0x200], 100)
    }
    func testUnsupportedChecksumFailsClosed() throws {
        var image = try syntheticImage()
        try image.replace(at: 0x100, expected: [0x48], with: [0])
        XCTAssertNotNil(try T7Checksums.inspect(image).firmwareIssue)
        XCTAssertFalse(try T7Checksums.inspect(image).isValid)
        XCTAssertThrowsError(try T7Checksums.repaired(image))
    }
    func testDisabledF2Preserved() throws {
        var image = try syntheticImage()
        let field = try image.footer()[0xF2]!
        try image.replace(at: field.range.lowerBound, expected: field.physicalBytes, with: [0,0,0,0])
        let repaired = try T7Checksums.repaired(image)
        XCTAssertNil(try T7Checksums.inspect(repaired).f2)
        XCTAssertEqual(try repaired.footer()[0xF2]?.integer, 0)
    }
    func testEncodingsRoundTrip() throws {
        for encoding in CellEncoding.allCases {
            let values = [encoding.limits.lowerBound, 0, encoding.limits.upperBound]
            XCTAssertEqual(try encoding.decode(encoding.encode(values)), values)
        }
        XCTAssertEqual(try CellEncoding.s16.decode([0xFF,0xFE]), [-2])
        XCTAssertThrowsError(try CellEncoding.u16.decode([1]))
        XCTAssertThrowsError(try CellEncoding.s8.encode([128]))
    }
    func testMapDimensions() throws {
        XCTAssertThrowsError(try MapGrid(bytes: [1,2,3], encoding: .u8, columns: 2))
        XCTAssertThrowsError(try MapGrid(bytes: [], encoding: .u8, columns: 0))
        let map = try MapGrid(bytes: [1,2,3,4], encoding: .u8, columns: 2)
        XCTAssertEqual(map.csv(), "1,2\n3,4\n")
    }
    func testTransformAtomic() throws {
        var map = try MapGrid(bytes: [10,250], encoding: .u8, columns: 2)
        XCTAssertThrowsError(try map.transform(indices: [0,1], add: 10))
        XCTAssertEqual(map.values, [10,250])
        try map.transform(indices: [0,1], multiply: 0.5)
        XCTAssertEqual(map.values, [5,125])
        XCTAssertThrowsError(try map.transform(indices: [0], add: .infinity))
    }
    func testPatchTransactionUndoRedo() throws {
        var session = EditSession(image: try syntheticImage())
        let patch = BinaryPatch(address: 0x200, before: [0], after: [99], reason: "Test")
        try session.apply([patch]); XCTAssertEqual(session.image.bytes[0x200], 99)
        try session.undo(); XCTAssertFalse(session.isModified)
        try session.redo(); XCTAssertEqual(session.image.bytes[0x200], 99)
        XCTAssertTrue(try T7Checksums.inspect(T7Image(data: session.verifiedExport())).isValid)
    }
    func testConflictIsAtomic() throws {
        var session = EditSession(image: try syntheticImage())
        let patches = [BinaryPatch(address: 0x200, before: [0], after: [1], reason: "A"), BinaryPatch(address: 0x201, before: [99], after: [2], reason: "B")]
        XCTAssertThrowsError(try session.apply(patches))
        XCTAssertFalse(session.isModified); XCTAssertTrue(session.undoStack.isEmpty)
    }
    func testOverlappingAndLengthChangingPatches() throws {
        var session = EditSession(image: try syntheticImage())
        let p = BinaryPatch(address: 0x200, before: [0], after: [1], reason: "A")
        XCTAssertThrowsError(try session.apply([p,p]))
        XCTAssertThrowsError(try session.apply([BinaryPatch(address: 0x200, before: [0], after: [1,2], reason: "B")]))
    }
    func testNewEditClearsRedo() throws {
        var session = EditSession(image: try syntheticImage())
        let p = BinaryPatch(address: 0x200, before: [0], after: [1], reason: "A")
        try session.apply([p]); try session.undo(); try session.apply([p])
        XCTAssertTrue(session.redoStack.isEmpty)
    }
    func testProjectRoundTripAndUndo() throws {
        var session = EditSession(image: try syntheticImage())
        try session.apply([BinaryPatch(address: 0x200, before: [0], after: [7], reason: "Persist")])
        var restored = try T7Project.restore(T7Project(session: session).encode())
        XCTAssertEqual(restored.image.bytes, session.image.bytes)
        try restored.undo(); XCTAssertEqual(restored.image.bytes, session.original.bytes)
    }
    func testProjectTampering() throws {
        let session = EditSession(image: try syntheticImage())
        let data = try T7Project(session: session).encode()
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["version"] = 999
        XCTAssertThrowsError(try T7Project.restore(JSONSerialization.data(withJSONObject: object)))
    }
    func testBinaryDiffBoundaries() throws {
        let a = try syntheticImage(); var b = a
        for p in [0,1,3,T7Image.size - 1] { try b.replace(at: p, expected: [b.bytes[p]], with: [b.bytes[p] ^ 1]) }
        XCTAssertEqual(BinaryDiff.compare(a,b).map(\.range), [0..<2,3..<4,(T7Image.size - 1)..<T7Image.size])
    }
    func testLogCommaDecimalAndFractionalSeconds() throws {
        let data = Data("06/09/2026 12:01:01.001|RPM=800|Lambda=1,02|\n06/09/2026 12:01:01.101|RPM=900|Lambda=1.01|\n".utf8)
        let log = try T7Log.parse(data)
        XCTAssertEqual(log.samples.count, 2); XCTAssertEqual(log.rejectedLines, 0)
        XCTAssertEqual(log.samples[0].values["Lambda"], 1.02)
        XCTAssertEqual(log.samples[1].elapsed, 0.1, accuracy: 0.0001)
        XCTAssertTrue(log.csv().contains("timestamp_local_unspecified"))
    }
    func testLogRejectsMalformedAndNonFinite() throws {
        let log = try T7Log.parse(Data("06/09/2026 12:00:00|RPM=800|\nBAD\n06/09/2026 12:00:01|RPM=NaN|\n06/09/2026 12:00:02|RPM=1|RPM=2|\n".utf8))
        XCTAssertEqual(log.rejectedLines, 3); XCTAssertEqual(log.samples.count, 1)
        XCTAssertThrowsError(try T7Log.parse(Data("bad".utf8)))
    }
    func testLogCSVFormulaEscaping() throws {
        let log = try T7Log.parse(Data("06/09/2026 12:00:00|+DANGER=1|".utf8))
        XCTAssertTrue(log.csv().contains("\"'+DANGER\""))
    }
    func testXMLExactSoftwareAndAddressMatch() throws {
        let symbol = T7Symbol(id: 0, name: "Symbolnumber 0", address: 100, length: 4, type: 0, flashAddress: 100)
        let table = SymbolTable(symbols: [symbol], packed: true, namesEmbedded: false, sramOffset: nil, warnings: [])
        let xml = Data("<DocumentElement><TEST.001><SYMBOLNUMBER>0</SYMBOLNUMBER><FLASHADDRESS>100</FLASHADDRESS><DESCRIPTION>TestCal.Map</DESCRIPTION></TEST.001></DocumentElement>".utf8)
        XCTAssertEqual(try T7SymbolXML.applying(xml, to: table, software: "TEST.001").symbols[0].name, "TestCal.Map")
        XCTAssertThrowsError(try T7SymbolXML.applying(xml, to: table, software: "OTHER"))
        XCTAssertThrowsError(try T7SymbolXML.applying(Data(String(decoding: xml, as: UTF8.self).replacingOccurrences(of: ">100<", with: ">101<").utf8), to: table, software: "TEST.001"))
    }
    func testXMLRejectsEntities() throws {
        let table = SymbolTable(symbols: [], packed: true, namesEmbedded: false, sramOffset: nil, warnings: [])
        XCTAssertThrowsError(try T7SymbolXML.applying(Data("<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><DocumentElement/>".utf8), to: table, software: "TEST"))
    }
    func testCompressionRejectsTruncationAndBombs() throws {
        XCTAssertThrowsError(try T7SymbolCompression.expand([]))
        XCTAssertThrowsError(try T7SymbolCompression.expand([255,255,255,127]))
        XCTAssertThrowsError(try T7SymbolCompression.expand([1,0,0,0]))
        for n in 0..<64 { XCTAssertThrowsError(try T7SymbolCompression.expand([1,0,0,0] + [UInt8](repeating: UInt8(n), count: 0))) }
    }
    func testAdaptiveHuffmanRescaleInvariants() {
        var tree = AdaptiveHuffman()
        for _ in 0..<40000 { tree.update(65) }
        XCTAssertLessThan(tree.weights[AdaptiveHuffman.root], 0x8000)
        for symbol in 0..<314 { XCTAssertEqual(tree.children[tree.leaves[symbol]], symbol + 627) }
        for node in 0..<627 where tree.children[node] < 627 {
            let child = tree.children[node]
            XCTAssertEqual(tree.parents[child], node); XCTAssertEqual(tree.parents[child + 1], node)
            XCTAssertEqual(tree.weights[node], tree.weights[child] + tree.weights[child + 1])
        }
    }
    func testCompressionLiteralRoundTripAcrossRescale() throws {
        // A literal-only encoder exercises >32768 symbols, forcing rescale. Tree invariants
        // above are independently checked; real compressed/back-reference data is corpus-tested.
        let input = (0..<40000).map { UInt8($0 % 251) }
        var tree = AdaptiveHuffman(), bits: [Int] = []
        for byte in input {
            var path: [Int] = [], node = tree.leaves[Int(byte)]
            while node != AdaptiveHuffman.root {
                let parent = tree.parents[node]; path.append(node - tree.children[parent]); node = parent
            }
            bits += path.reversed(); tree.update(Int(byte))
        }
        var stream = try Bytes.encoded(UInt32(input.count), width: 4, littleEndian: true)
        for p in stride(from: 0, to: bits.count, by: 8) {
            var value: UInt8 = 0
            for bit in 0..<8 { value <<= 1; if p + bit < bits.count { value |= UInt8(bits[p + bit]) } }
            stream.append(value)
        }
        XCTAssertEqual(try T7SymbolCompression.expand(stream), input)
    }
    func testUnknownSymbolsRejected() throws { XCTAssertThrowsError(try T7Symbols.parse(syntheticImage())) }

    func testPrivateFirmwareCorpus() throws {
        guard let folder = ProcessInfo.processInfo.environment["T7_CORPUS"] else { throw XCTSkip("Private firmware is deliberately not redistributed. Set T7_CORPUS to run the corpus test.") }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "bin" }
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            let image = try T7Image(data: Data(contentsOf: url))
            XCTAssertTrue(try T7Checksums.inspect(image).isValid, url.lastPathComponent)
            XCTAssertEqual(try T7Checksums.repaired(image).bytes, image.bytes, url.lastPathComponent)
            let symbols = try T7Symbols.parse(image)
            XCTAssertFalse(symbols.symbols.isEmpty, url.lastPathComponent)
            // Mutation exercises BOTH firmware and global checksum repair, not just stock reads.
            let region = try T7Checksums.layout(image, footer: image.footer()).regions[0]
            var changed = image
            try changed.replace(at: region.lowerBound, expected: [image.bytes[region.lowerBound]], with: [image.bytes[region.lowerBound] ^ 1])
            XCTAssertFalse(try T7Checksums.inspect(changed).isValid, url.lastPathComponent)
            XCTAssertTrue(try T7Checksums.inspect(T7Checksums.repaired(changed)).isValid, url.lastPathComponent)
        }
        print("PRIVATE CORPUS: \(urls.count) stock inspection, idempotence, symbol parsing and mutation/repair checks passed.")
    }
}
