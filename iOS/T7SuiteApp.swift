// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UniformTypeIdentifiers
import T7Core

@main struct T7SuiteApp: App {
    @StateObject private var model = Workspace()
    var body: some Scene { WindowGroup { RootView(model: model).tint(.green) } }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum ImportPurpose: String, Identifiable, Sendable {
    case binary, project, compare, log, symbols
    var id: String { rawValue }
}
struct LoadedFirmware: Sendable {
    let session: EditSession
    let footer: T7Footer
    let symbols: SymbolTable?
    let symbolIssue: String?
    let xml: Data?
    init(session: EditSession, xml: Data? = nil) throws {
        let parsedFooter = try session.image.footer()
        self.session = session; footer = parsedFooter; self.xml = xml
        do {
            let table = try T7Symbols.parse(session.image)
            if let xml { symbols = try T7SymbolXML.applying(xml, to: table, software: parsedFooter.software) }
            else { symbols = table }
            symbolIssue = nil
        } catch { symbols = nil; symbolIssue = error.localizedDescription }
    }
}
enum ImportedData: Sendable {
    case firmware(LoadedFirmware), comparison([Difference]), log(T7Log), symbols(SymbolTable, Data)
}

@MainActor final class Workspace: ObservableObject {
    @Published var session: EditSession?
    @Published var footer: T7Footer?
    @Published var symbols: SymbolTable?
    @Published var symbolIssue: String?
    @Published var checksums: ChecksumReport?
    @Published var checksumIssue: String?
    @Published var fileName = "Ingen fil öppnad"
    @Published var differences: [Difference] = []
    @Published var comparisonName: String?
    @Published var log: T7Log?
    @Published var busy = false
    @Published var error: String?
    @Published var revision = 0
    @Published var export: ExportDocument?
    @Published var exportName = "export.bin"
    @Published var showExporter = false
    @Published var acknowledgeCalibrationRisk = false
    private var symbolXML: Data?
    var canUndo: Bool { session?.undoStack.isEmpty == false }
    var canRedo: Bool { session?.redoStack.isEmpty == false }

    func importFile(_ url: URL, purpose: ImportPurpose) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let current = session, currentSymbols = symbols, software = footer?.software
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 32 * 1024 * 1024 else { throw T7Error.invalid("Filen är större än 32 MiB.") }
                let data = try Data(contentsOf: url)
                switch purpose {
                case .binary:
                    return ImportedData.firmware(try LoadedFirmware(session: EditSession(image: T7Image(data: data))))
                case .project:
                    let restored = try T7Project.restore(data)
                    let archive = try JSONDecoder().decode(T7Project.self, from: data)
                    return ImportedData.firmware(try LoadedFirmware(session: restored, xml: archive.symbolXML))
                case .compare:
                    guard let current else { throw T7Error.invalid("Öppna först en BIN-fil.") }
                    return ImportedData.comparison(BinaryDiff.compare(current.image, try T7Image(data: data)))
                case .log: return ImportedData.log(try T7Log.parse(data))
                case .symbols:
                    guard let currentSymbols, let software else { throw T7Error.invalid("Öppna först en fil med identifierad symboltabell.") }
                    return ImportedData.symbols(try T7SymbolXML.applying(data, to: currentSymbols, software: software), data)
                }
            }.value
            switch imported {
            case .firmware(let value):
                session = value.session; footer = value.footer; symbols = value.symbols
                symbolIssue = value.symbolIssue; symbolXML = value.xml; fileName = url.lastPathComponent
                differences = []; comparisonName = nil; checksums = nil; checksumIssue = nil
                acknowledgeCalibrationRisk = false; revision += 1
            case .comparison(let rows): differences = rows; comparisonName = url.lastPathComponent
            case .log(let value): log = value
            case .symbols(let table, let xml): symbols = table; symbolIssue = nil; symbolXML = xml
            }
        } catch { self.error = error.localizedDescription }
    }
    func recheck() async {
        guard let image = session?.image else { return }
        let version = revision
        do {
            let result = try await Task.detached(priority: .userInitiated) { try T7Checksums.inspect(image) }.value
            guard version == revision, !Task.isCancelled else { return }
            checksums = result; checksumIssue = nil
        } catch { if version == revision && !Task.isCancelled { checksumIssue = error.localizedDescription } }
    }
    func edit(symbol: T7Symbol, encoding: CellEncoding, index: Int, value: Int) throws {
        guard !busy, acknowledgeCalibrationRisk, symbol.isEditable, let address = symbol.flashAddress, var current = session,
              index >= 0, index < symbol.length / encoding.width else { throw T7Error.unsupported("Symbolen är skrivskyddad eller redigering är inte aktiverad.") }
        let offset = address + index * encoding.width
        let patch = BinaryPatch(address: offset, before: try current.image.read(at: offset, count: encoding.width),
                                after: try encoding.encode([value]), reason: "\(symbol.name), cell \(index), \(encoding.rawValue)")
        try current.apply([patch]); session = current; changed()
    }
    func undo() { do { try session?.undo(); changed() } catch { self.error = error.localizedDescription } }
    func redo() { do { try session?.redo(); changed() } catch { self.error = error.localizedDescription } }
    private func changed() {
        checksums = nil; checksumIssue = nil; comparisonName = nil; differences = []; revision += 1
    }
    func prepareExport(project: Bool) async {
        guard let snapshot = session, !busy else { return }
        busy = true; defer { busy = false }
        let xml = symbolXML
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try project ? T7Project(session: snapshot, symbolXML: xml).encode() : snapshot.verifiedExport()
            }.value
            let base = (fileName as NSString).deletingPathExtension
            exportName = base + (project ? ".t7project" : "-edited.bin")
            export = ExportDocument(data: data); showExporter = true
        } catch { self.error = error.localizedDescription }
    }
    func exportCSV(_ string: String, name: String) {
        export = ExportDocument(data: Data(string.utf8)); exportName = name; showExporter = true
    }
}
