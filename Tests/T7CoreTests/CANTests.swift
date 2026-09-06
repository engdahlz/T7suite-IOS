import XCTest
@testable import T7Core

final class CANTests: XCTestCase, @unchecked Sendable {
    func frame(_ bytes: [UInt8], id: UInt32 = 0x258) throws -> CANFrame { try CANFrame(id: id, data: bytes) }
    func testRequestVINFrame() throws {
        XCTAssertEqual(try KWPCodec.request(service: 0x1A, parameters: [0x90]), [try CANFrame(id: 0x240, data: [0x40,0xA1,2,0x1A,0x90,0,0,0])])
    }
    func testRequestFragmentBoundaries() throws {
        for n in [0,3,4,5,10,254] {
            let parameters = (0..<n).map { UInt8(truncatingIfNeeded: $0) }
            let rows = try KWPCodec.request(service: 0x21, parameters: parameters)
            XCTAssertEqual(rows.count, (n + 7) / 6)
            let assembled = rows.flatMap { $0.data.dropFirst(2) }
            XCTAssertEqual(Array(assembled.prefix(n + 2)), [UInt8(n + 1),0x21] + parameters)
        }
        XCTAssertThrowsError(try KWPCodec.request(service: 0x21, parameters: [UInt8](repeating: 0, count: 255)))
    }
    func testVINTranscriptAndACKs() throws {
        let rows: [[UInt8]] = [[0xC3,0xBF,0x13,0x5A,0x90,0x59,0x53,0x33],
                              [0x82,0xBF,0x45,0x46,0x35,0x38,0x43,0x39],
                              [0x81,0xBF,0x59,0x31,0x32,0x33,0x34,0x35],
                              [0x80,0xBF,0x36,0x37,0,0,0,0]]
        var assembler = KWPAssembler(), answer: [UInt8]?
        for (i, row) in rows.enumerated() {
            let result = try XCTUnwrap(assembler.accept(frame(row)))
            XCTAssertEqual(result.ack.id, 0x266)
            XCTAssertEqual(result.ack.data, [0x40,0xA1,0x3F,UInt8(0x83 - i),0,0,0,0])
            answer = result.payload
        }
        let vin = try KWPCodec.positive(XCTUnwrap(answer), for: 0x1A, echo: [0x90])
        XCTAssertEqual(String(bytes: vin, encoding: .ascii), "YS3EF58C9Y1234567")
        XCTAssertTrue(assembler.complete)
        XCTAssertThrowsError(try assembler.accept(frame(rows[3])))
    }
    func testMalformedFrameAndCANBounds() throws {
        XCTAssertThrowsError(try CANFrame(id: 0x800, data: [1]))
        XCTAssertThrowsError(try CANFrame(id: 1, data: [UInt8](repeating: 0, count: 9)))
        XCTAssertThrowsError(try JSONDecoder().decode(CANFrame.self, from: Data("{\"id\":2048,\"data\":[1]}".utf8)))
        var assembler = KWPAssembler()
        XCTAssertThrowsError(try assembler.accept(frame([0xC0,0xBF])))
    }
    func testMissingFirstAndOutOfOrder() throws {
        var a = KWPAssembler()
        XCTAssertThrowsError(try a.accept(frame([0x80,0xBF,1,2,3,4,5,6])))
        _ = try a.accept(frame([0xC2,0xBF,12,0x5A,0x90,1,2,3]))
        XCTAssertThrowsError(try a.accept(frame([0x80,0xBF,1,2,3,4,5,6])))
    }
    func testLengthMismatchAndUnrelatedTraffic() throws {
        var a = KWPAssembler()
        XCTAssertNil(try a.accept(CANFrame(id: 0x123, data: [1])))
        XCTAssertThrowsError(try a.accept(frame([0xC3,0xBF,2,0x5A,0x90,0,0,0])))
    }
    func testNegativeResponseAndEchoValidation() throws {
        XCTAssertThrowsError(try KWPCodec.positive([0x7F,0x1A,0x78], for: 0x1A)) { error in XCTAssertTrue((error as? KWPRejection)?.isPending == true) }
        XCTAssertThrowsError(try KWPCodec.positive([0x7F,0x1A], for: 0x1A))
        XCTAssertThrowsError(try KWPCodec.positive([0x5A,0x91,1], for: 0x1A, echo: [0x90]))
        XCTAssertEqual(try KWPCodec.positive([0x5A,0x90,7], for: 0x1A, echo: [0x90]), [7])
    }
    func testReadSession() async throws {
        let transport = ReplayTransport(frames: [try frame([0xC0,0xBF,3,0x5A,0x90,7,0,0])])
        let session = KWPReadSession(establishedTransport: transport)
        let answer = try await session.readIdentifier(0x90)
        XCTAssertEqual(answer, [7])
        let sent = await transport.sent
        XCTAssertEqual(sent.count, 2); XCTAssertEqual(sent.last?.id, 0x266)
    }
    func testPendingThenSuccess() async throws {
        let transport = ReplayTransport(frames: [try frame([0xC0,0xBF,3,0x7F,0x1A,0x78,0,0]), try frame([0xC0,0xBF,3,0x5A,0x90,7,0,0])])
        let session = KWPReadSession(establishedTransport: transport)
        let answer = try await session.readIdentifier(0x90)
        XCTAssertEqual(answer, [7])
    }
    func testTimeoutInvalidatesSession() async throws {
        let transport = ReplayTransport(frames: [])
        let session = KWPReadSession(establishedTransport: transport)
        do { _ = try await session.readIdentifier(0x90); XCTFail("Expected timeout") } catch { XCTAssertEqual(error as? T7Error, .timeout) }
        do { _ = try await session.readIdentifier(0x90); XCTFail("Expected closed session") } catch { XCTAssertEqual(error as? T7Error, .disconnected) }
        let closed = await transport.closed; XCTAssertTrue(closed)
    }
}
actor ReplayTransport: CANTransport {
    var frames: [CANFrame]
    var sent: [CANFrame] = []
    var closed = false
    init(frames: [CANFrame]) { self.frames = frames }
    func send(_ frame: CANFrame) async throws { if closed { throw T7Error.disconnected }; sent.append(frame) }
    func receive(timeout: Duration) async throws -> CANFrame {
        if frames.isEmpty { throw T7Error.timeout }; return frames.removeFirst()
    }
    func close() async { closed = true }
}
