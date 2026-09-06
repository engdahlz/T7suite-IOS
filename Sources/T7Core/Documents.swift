// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct T7Project: Codable, Sendable {
    public let version: Int
    public let original: Data
    public let transactions: [[BinaryPatch]]
    public let symbolXML: Data?
    public init(session: EditSession, symbolXML: Data? = nil) {
        version = 1; original = session.original.data; transactions = session.undoStack; self.symbolXML = symbolXML
    }
    public func encode() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    public static func restore(_ data: Data) throws -> EditSession {
        guard data.count <= 32 * 1024 * 1024 else { throw T7Error.invalid("project size limit") }
        let project = try JSONDecoder().decode(Self.self, from: data)
        guard project.version == 1, project.transactions.count <= 4096 else { throw T7Error.unsupported("project version or history size") }
        var session = EditSession(image: try T7Image(data: project.original))
        for transaction in project.transactions {
            guard transaction.count <= 20000, transaction.allSatisfy({ $0.reason.utf8.count <= 4096 }) else { throw T7Error.invalid("project transaction limits") }
            try session.apply(transaction)
        }
        return session
    }
}

public struct LogSample: Identifiable, Sendable {
    public let id: Int
    public let timestamp: String
    public let elapsed: Double
    public let values: [String: Double]
}
public struct T7Log: Sendable {
    public let samples: [LogSample]
    public let channels: [String]
    public let rejectedLines: Int
    public let warnings: [String]
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 20 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw T7Error.invalid("log must be UTF-8 and at most 20 MiB") }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = Calendar(identifier: .gregorian)
        // Legacy timestamps have no timezone. UTC here is only a stable coordinate for elapsed
        // time; this does NOT identify the actual timezone or absolute instant of the log.
        format.timeZone = TimeZone(secondsFromGMT: 0); format.isLenient = false
        var samples: [LogSample] = [], warnings: [String] = [], rejected = 0, channels = Set<String>()
        var first: Date?, previous: Date?
        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            guard index < 200000 else { throw T7Error.invalid("log row limit") }
            do {
                guard raw.utf8.count <= 65536 else { throw T7Error.invalid("log line length") }
                let fields = raw.split(separator: "|", omittingEmptySubsequences: true)
                guard let time = fields.first, time.count == 19 || time.count == 23 else { throw T7Error.invalid("timestamp length") }
                format.dateFormat = time.count == 23 ? "dd/MM/yyyy HH:mm:ss.SSS" : "dd/MM/yyyy HH:mm:ss"
                guard let date = format.date(from: String(time)), format.string(from: date) == time else { throw T7Error.invalid("timestamp format") }
                guard previous == nil || date >= previous! else { throw T7Error.invalid("timestamp moved backwards") }
                var values: [String: Double] = [:]
                for field in fields.dropFirst() {
                    let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2, !pair[0].isEmpty, pair[0].count <= 512 else { throw T7Error.invalid("log name=value pair") }
                    let name = String(pair[0]), rawValue = pair[1].trimmingCharacters(in: .whitespaces)
                    guard !(rawValue.contains(",") && rawValue.contains(".")),
                          let number = Double(rawValue.replacingOccurrences(of: ",", with: ".")), number.isFinite,
                          values[name] == nil else { throw T7Error.invalid("duplicate channel or invalid number") }
                    values[name] = number
                }
                guard !values.isEmpty else { throw T7Error.invalid("empty sample") }
                if first == nil { first = date }; previous = date
                channels.formUnion(values.keys)
                samples.append(LogSample(id: index, timestamp: String(time), elapsed: date.timeIntervalSince(first!), values: values))
            } catch {
                rejected += 1
                if warnings.count < 100 { warnings.append("Line \(index + 1): \(error.localizedDescription)") }
            }
        }
        guard !samples.isEmpty else { throw T7Error.invalid("no valid log samples (\(rejected) rejected)") }
        return Self(samples: samples, channels: channels.sorted(), rejectedLines: rejected, warnings: warnings)
    }
    public func csv() -> String {
        func quote(_ value: String) -> String {
            let safe = value.first.map { "=+-@\t\r".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = (["timestamp_local_unspecified", "elapsed_seconds"] + channels).map(quote).joined(separator: ",")
        let rows = samples.map { sample in
            ([quote(sample.timestamp), String(sample.elapsed)] + channels.map { sample.values[$0].map(String.init(describing:)) ?? "" }).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}

public enum T7SymbolXML {
    private final class Reader: NSObject, XMLParserDelegate {
        let software: String
        var stack: [String] = [], fields: [String: String] = [:], entries: [(Int, String, Int)] = []
        var failure: Error?
        init(software: String) { self.software = software }
        func fail(_ parser: XMLParser, _ message: String) { failure = T7Error.invalid(message); parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            stack.append(elementName)
            switch stack.count {
            case 1: if elementName != "DocumentElement" { fail(parser, "symbol XML root") }
            case 2:
                fields = [:]
                if elementName != software { fail(parser, "symbol XML software must exactly match \(software)") }
            case 3:
                if !["SYMBOLNAME", "SYMBOLNUMBER", "FLASHADDRESS", "DESCRIPTION"].contains(elementName) || fields[elementName] != nil { fail(parser, "symbol XML field") }
                fields[elementName] = ""
            default: fail(parser, "symbol XML nesting")
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard stack.count == 3, let field = stack.last else { return }
            fields[field, default: ""] += string
            if fields[field]!.utf8.count > 1024 { fail(parser, "symbol XML text length") }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if stack.count == 2 {
                guard let n = fields["SYMBOLNUMBER"].flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), n >= 0,
                      let address = fields["FLASHADDRESS"].flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), address > 0,
                      let name = fields["DESCRIPTION"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                      entries.count < 20000 else { fail(parser, "symbol XML entry"); return }
                entries.append((n, name, address))
            }
            if !stack.isEmpty { stack.removeLast() }
        }
    }
    public static func applying(_ data: Data, to table: SymbolTable, software: String) throws -> SymbolTable {
        guard data.count <= 10 * 1024 * 1024, let xml = String(data: data, encoding: .utf8),
              !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw T7Error.invalid("XML size, encoding or external entity declaration") }
        let reader = Reader(software: software), parser = XMLParser(data: data)
        parser.delegate = reader; parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.failure == nil, !reader.entries.isEmpty else { throw reader.failure ?? T7Error.invalid("symbol XML syntax/empty") }
        var symbols = table.symbols, seen = Set<Int>()
        for (id, name, address) in reader.entries {
            guard symbols.indices.contains(id), symbols[id].id == id, seen.insert(id).inserted,
                  symbols[id].flashAddress == address || Int(symbols[id].address) == address else { throw T7Error.invalid("XML symbol index/address mismatch at \(id)") }
            if table.namesEmbedded && symbols[id].name != name { throw T7Error.invalid("XML conflicts with embedded symbol name") }
            symbols[id].name = name
        }
        return SymbolTable(symbols: symbols, packed: table.packed, namesEmbedded: table.namesEmbedded, sramOffset: table.sramOffset,
                           warnings: table.warnings + ["Imported \(reader.entries.count) software- and address-matched XML names. This does not verify units or dimensions."])
    }
}
