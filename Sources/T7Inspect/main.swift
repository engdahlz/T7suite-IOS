import Foundation
import T7Core

@main struct Inspect {
    static func main() throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            print("Usage: t7inspect firmware.bin [firmware.bin ...]\nRead-only inspection; no ECU connection.")
            return
        }
        for path in paths {
            var result: [String: Any] = ["file": URL(fileURLWithPath: path).lastPathComponent]
            do {
                let image = try T7Image(data: Data(contentsOf: URL(fileURLWithPath: path)))
                let footer = try image.footer()
                result["software"] = footer.software
                do {
                    let sums = try T7Checksums.inspect(image)
                    result["checksumsValid"] = sums.isValid
                    result["fbMatches"] = sums.fb.matches
                    result["f2Matches"] = sums.f2?.matches
                    result["firmwareMatches"] = sums.firmware?.matches
                    result["firmwareIssue"] = sums.firmwareIssue
                    if !sums.isValid {
                        result["fbStored"] = String(format: "%08X", sums.fb.stored)
                        result["fbCalculated"] = String(format: "%08X", sums.fb.calculated)
                        result["fwStored"] = sums.firmware.map { String(format: "%08X", $0.stored) }
                        result["fwCalculated"] = sums.firmware.map { String(format: "%08X", $0.calculated) }
                    }
                } catch { result["checksumError"] = error.localizedDescription }
                do {
                    let table = try T7Symbols.parse(image)
                    result["symbols"] = table.symbols.count
                    result["namedSymbols"] = table.namesEmbedded
                    result["packed"] = table.packed
                    result["warnings"] = table.warnings
                    result["editableSymbols"] = table.symbols.filter(\.isEditable).count
                } catch { result["symbolError"] = error.localizedDescription }
            } catch { result["error"] = error.localizedDescription }
            let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        }
    }
}
