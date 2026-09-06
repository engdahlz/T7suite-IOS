// SPDX-License-Identifier: Apache-2.0
// Saab legacy KWP-over-CAN, NOT ISO-TP. See T7CANFlasher/KWP/KWPCANDevice.cs.
import Foundation

public struct CANFrame: Equatable, Sendable, Codable {
    public let id: UInt32
    public let data: [UInt8]
    public init(id: UInt32, data: [UInt8]) throws {
        guard id <= 0x7FF, (1...8).contains(data.count) else { throw T7Error.invalid("standard CAN frame") }
        self.id = id; self.data = data
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UInt32.self, forKey: .id), data: c.decode([UInt8].self, forKey: .data))
    }
    public var hex: String { String(format: "%03X", id) + " " + data.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

public enum KWPCodec {
    public static func request(service: UInt8, parameters: [UInt8] = []) throws -> [CANFrame] {
        guard parameters.count <= 254 else { throw T7Error.invalid("KWP payload exceeds one-byte length") }
        let payload = [UInt8(parameters.count + 1), service] + parameters
        let count = (payload.count + 5) / 6
        return try (0..<count).map { row in
            let start = row * 6, end = min(start + 6, payload.count)
            var data = [UInt8(count - row - 1) | (row == 0 ? 0x40 : 0), 0xA1] + Array(payload[start..<end])
            data += [UInt8](repeating: 0, count: 8 - data.count)
            return try CANFrame(id: 0x240, data: data)
        }
    }
    public static func acknowledgement(remainingRows: Int) throws -> CANFrame {
        guard (0...42).contains(remainingRows) else { throw T7Error.invalid("KWP row count") }
        return try CANFrame(id: 0x266, data: [0x40, 0xA1, 0x3F, 0x80 | UInt8(remainingRows), 0, 0, 0, 0])
    }
    public static func positive(_ payload: [UInt8], for service: UInt8, echo: [UInt8] = []) throws -> [UInt8] {
        if payload.first == 0x7F {
            guard payload.count == 3, payload[1] == service else { throw T7Error.invalid("malformed KWP negative response") }
            throw KWPRejection(service: service, code: payload[2])
        }
        guard service <= 0xBF, payload.first == service + 0x40, payload.count >= 1 + echo.count,
              Array(payload.dropFirst().prefix(echo.count)) == echo else { throw T7Error.invalid("KWP response service/identifier mismatch") }
        return Array(payload.dropFirst(1 + echo.count))
    }
}
public struct KWPRejection: Error, Equatable, Sendable, LocalizedError {
    public let service: UInt8
    public let code: UInt8
    public var errorDescription: String? { String(format: "ECU rejected service %02X (response %02X).", service, code) }
    public var isPending: Bool { code == 0x78 }
}

public struct KWPAssembler: Sendable {
    private var buffer: [UInt8] = []
    private var remaining: Int?
    private var expectedLength: Int?
    public private(set) var complete = false
    public init() {}
    // Unrelated CAN IDs are ignored; malformed/misordered relevant frames are rejected.
    // The caller must send the ACK even when this returns the final payload.
    public mutating func accept(_ frame: CANFrame) throws -> (ack: CANFrame, payload: [UInt8]?)? {
        guard frame.id == 0x258 else { return nil }
        guard !complete, frame.data.count == 8, frame.data[1] == 0xBF else { throw T7Error.invalid("KWP response frame") }
        let header = frame.data[0], rows = Int(header & 0x3F)
        if remaining == nil {
            guard header & 0xC0 == 0xC0 else { throw T7Error.invalid("missing KWP first frame") }
            let length = Int(frame.data[2]) + 1
            guard length >= 2, (length + 5) / 6 - 1 == rows else { throw T7Error.invalid("KWP declared length/row count") }
            expectedLength = length
        } else {
            guard header & 0xC0 == 0x80, rows == remaining! - 1 else { throw T7Error.invalid("KWP frame sequence") }
        }
        remaining = rows; buffer += frame.data.dropFirst(2)
        guard let length = expectedLength, buffer.count <= 258 else { throw T7Error.invalid("KWP assembly size") }
        let ack = try KWPCodec.acknowledgement(remainingRows: rows)
        if rows == 0 {
            guard buffer.count >= length else { throw T7Error.invalid("truncated KWP response") }
            complete = true
            return (ack, Array(buffer[1..<length]))
        }
        return (ack, nil)
    }
}

/// A future adapter must provide bounded, cancellation-aware operations. No USB/BLE adapter
/// compatibility is implied by this protocol. Session initialization is adapter-specific.
public protocol CANTransport: Sendable {
    func send(_ frame: CANFrame) async throws
    func receive(timeout: Duration) async throws -> CANFrame
    func close() async
}

/// Read-only transaction engine for an ALREADY established Saab KWP session.
/// No session-open, seed/key, SRAM writes, actuator tests, clear-DTC, erase or flash API.
public actor KWPReadSession {
    private let transport: any CANTransport
    private var busy = false
    private var valid = true
    public init(establishedTransport: any CANTransport) { transport = establishedTransport }
    public func close() async { valid = false; await transport.close() }
    public func readIdentifier(_ id: UInt8, timeout: Duration = .seconds(2)) async throws -> [UInt8] {
        try await transact(service: 0x1A, parameters: [id], echo: [id], timeout: timeout)
    }
    public func testerPresent(timeout: Duration = .seconds(2)) async throws {
        _ = try await transact(service: 0x3E, parameters: [], echo: [], timeout: timeout)
    }
    private func transact(service: UInt8, parameters: [UInt8], echo: [UInt8], timeout: Duration) async throws -> [UInt8] {
        guard valid else { throw T7Error.disconnected }
        guard !busy else { throw T7Error.busy }
        guard timeout > .zero, timeout <= .seconds(10) else { throw T7Error.invalid("transaction timeout") }
        busy = true; defer { busy = false }
        do {
            try Task.checkCancellation()
            for frame in try KWPCodec.request(service: service, parameters: parameters) { try await transport.send(frame) }
            let clock = ContinuousClock(), deadline = clock.now + timeout
            var assembler = KWPAssembler(), count = 0
            while clock.now < deadline {
                try Task.checkCancellation()
                guard valid else { throw T7Error.disconnected }
                count += 1
                guard count <= 4096 else { throw T7Error.invalid("excess CAN traffic") }
                let frame = try await transport.receive(timeout: clock.now.duration(to: deadline))
                if let result = try assembler.accept(frame) {
                    try await transport.send(result.ack)
                    if let payload = result.payload {
                        do { return try KWPCodec.positive(payload, for: service, echo: echo) }
                        catch let error as KWPRejection where error.isPending { assembler = KWPAssembler() }
                    }
                }
            }
            throw T7Error.timeout
        } catch {
            // Never reuse a stream after timeout/cancellation: a delayed reply could otherwise
            // be mistaken for the next transaction. Explicit re-establishment is mandatory.
            valid = false; await transport.close(); throw error
        }
    }
}
