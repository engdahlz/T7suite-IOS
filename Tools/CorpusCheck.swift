// Compile together with the core, preserving access to checksum layout for mutation tests:
// swiftc -O Sources/T7Core/*.swift Tools/CorpusCheck.swift -o /tmp/t7-corpus
// /tmp/t7-corpus /private/path/T7Binaries
import Foundation

@main struct CorpusCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw T7Error.invalid("usage: t7-corpus T7Binaries-directory") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw T7Error.invalid("empty corpus") }
        for file in files {
            let image = try T7Image(data: Data(contentsOf: file))
            guard try T7Checksums.inspect(image).isValid else { throw T7Error.invalid("stock checksum: \(file.lastPathComponent)") }
            guard try T7Checksums.repaired(image).bytes == image.bytes else { throw T7Error.invalid("non-idempotent repair: \(file.lastPathComponent)") }
            let symbols = try T7Symbols.parse(image)
            guard !symbols.symbols.isEmpty else { throw T7Error.invalid("empty symbols") }
            let region = try T7Checksums.layout(image, footer: image.footer()).regions[0]
            var changed = image
            try changed.replace(at: region.lowerBound, expected: [image.bytes[region.lowerBound]], with: [image.bytes[region.lowerBound] ^ 1])
            guard try !T7Checksums.inspect(changed).isValid else { throw T7Error.invalid("mutation not detected") }
            guard try T7Checksums.inspect(T7Checksums.repaired(changed)).isValid else { throw T7Error.invalid("mutation repair failed") }
            let result: [String: Any] = ["file": file.lastPathComponent, "software": try image.footer().software,
                "symbols": symbols.symbols.count, "packed": symbols.packed, "namesEmbedded": symbols.namesEmbedded,
                "stockChecksums": true, "repairIdempotent": true, "mutationDetected": true, "mutationRepair": true,
                "editableSymbols": symbols.symbols.filter(\.isEditable).count, "warnings": symbols.warnings]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
