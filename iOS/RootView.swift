// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import T7Core

struct RootView: View {
    @ObservedObject var model: Workspace
    @State private var importer = false
    @State private var purpose: ImportPurpose = .binary
    @State private var pendingPurpose: ImportPurpose?
    @State private var confirmReplace = false
    var body: some View {
        TabView {
            NavigationStack { FirmwareView(model: model, open: open).navigationTitle("T7Suite") }
                .tabItem { Label("Fil", systemImage: "doc.richtext") }
            NavigationStack { SymbolsView(model: model, open: open).navigationTitle("Kartor & symboler") }
                .tabItem { Label("Kartor", systemImage: "square.grid.3x3") }
            NavigationStack { HistoryView(model: model, open: open).navigationTitle("Ändringar") }
                .tabItem { Label("Historik", systemImage: "clock.arrow.circlepath") }
            NavigationStack { LogView(model: model, open: open).navigationTitle("Loggar") }
                .tabItem { Label("Loggar", systemImage: "waveform.path.ecg") }
            NavigationStack { ConnectionView().navigationTitle("Anslutning") }
                .tabItem { Label("Anslutning", systemImage: "cable.connector") }
        }
        .task(id: model.revision) { await model.recheck() }
        .disabled(model.busy)
        .overlay { if model.busy { ProgressView("Bearbetar fil…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            do { if let url = try result.get().first { Task { await model.importFile(url, purpose: purpose) } } }
            catch { model.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $model.showExporter, document: model.export, contentType: .data, defaultFilename: model.exportName) { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
        .alert("Det gick inte att slutföra", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Öppna en annan fil? Exportera projektet först för att behålla osparade ändringar.", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Öppna utan att spara", role: .destructive) { if let next = pendingPurpose { purpose = next; importer = true } }
            Button("Avbryt", role: .cancel) {}
        }
    }
    private func open(_ next: ImportPurpose) {
        if (next == .binary || next == .project) && model.session?.isModified == true {
            pendingPurpose = next; confirmReplace = true
        } else { purpose = next; importer = true }
    }
}

struct FirmwareView: View {
    @ObservedObject var model: Workspace
    let open: (ImportPurpose) -> Void
    var body: some View {
        List {
            Section {
                Label("Trionic 7 • iPhone", systemImage: "cpu").font(.title2.bold())
                Text("Lokal filanalys och kalibreringsredigering. Ingen bil behöver vara ansluten.").foregroundStyle(.secondary)
                Button("Öppna BIN-fil", systemImage: "folder") { open(.binary) }.accessibilityIdentifier("openBinary")
                Button("Öppna sparat projekt", systemImage: "clock.arrow.circlepath") { open(.project) }
            }
            if let session = model.session {
                Section("Arbetskopia") {
                    Text(model.fileName).font(.headline).textSelection(.enabled)
                    LabeledContent("Storlek", value: "512 KiB")
                    LabeledContent("Ändrad", value: session.isModified ? "Ja" : "Nej")
                    Text("Originalfilen skrivs aldrig över automatiskt. Projektet innehåller originalet och ändringshistoriken.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Checksummor") {
                    if let report = model.checksums {
                        ChecksumRow(name: "F2", value: report.f2, absent: "Ej aktiverad i denna fil")
                        ChecksumRow(name: "FB", value: report.fb)
                        ChecksumRow(name: "Firmware", value: report.firmware)
                        if let issue = report.firmwareIssue { Text(issue).foregroundStyle(.orange) }
                        Label(report.isValid ? "Alla aktiva kontroller stämmer" : "Filen behöver kontrolleras före export", systemImage: report.isValid ? "checkmark.shield" : "exclamationmark.shield")
                    } else if let issue = model.checksumIssue { Text(issue).foregroundStyle(.orange) }
                    else { ProgressView("Kontrollerar…") }
                    Text("En korrekt checksumma visar dataintegritet – inte att en kalibrering är säker för motorn.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Firmwareinformation") {
                    ForEach(model.footer?.fields.filter { [0x90,0x91,0x93,0x94,0x95,0x97,0x98,0x9A].contains($0.id) } ?? [], id: \.id) { field in
                        LabeledContent(field.label, value: field.text).textSelection(.enabled)
                    }
                }
                Section("Exportera") {
                    Button("Spara projekt med historik", systemImage: "tray.and.arrow.down") { Task { await model.prepareExport(project: true) } }
                    Button("Exportera BIN med kontrollerade checksummor", systemImage: "square.and.arrow.up") { Task { await model.prepareExport(project: false) } }
                    Text("Okända checksumformat blockerar BIN-export. ECU-skrivning ingår inte i denna version.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Utvecklingsversion") {
                Text("Detta är inte full funktionsparitet med Windows-versionen. Adapterstöd, flashning, autotune och andra ECU-skrivningar är inte aktiverade.").font(.footnote)
            }
        }
    }
}
struct ChecksumRow: View {
    let name: String
    let value: ChecksumValue?
    var absent = "Formatet kunde inte verifieras"
    var body: some View {
        HStack {
            Text(name)
            Spacer()
            if let value {
                VStack(alignment: .trailing) {
                    Label(value.matches ? "Stämmer" : "Avviker", systemImage: value.matches ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(value.matches ? Color.green : Color.orange)
                    Text(String(format: "%08X → %08X", value.stored, value.calculated)).font(.caption.monospaced())
                }
            } else { Text(absent).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct SymbolsView: View {
    @ObservedObject var model: Workspace
    let open: (ImportPurpose) -> Void
    @State private var query = ""
    @State private var calibrationOnly = true
    private var results: [T7Symbol] {
        (model.symbols?.symbols ?? []).filter { (!calibrationOnly || $0.isCalibration) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        List {
            if model.session == nil {
                ContentUnavailableView("Öppna en firmwarefil", systemImage: "doc.badge.plus", description: Text("Välj en T7 BIN-fil under fliken Fil."))
            } else {
                Section {
                    Toggle("Visa bara kalibreringar", isOn: $calibrationOnly)
                    Text("\(results.count) träffar · \(model.symbols?.symbols.count ?? 0) symboler totalt").font(.caption).foregroundStyle(.secondary)
                    Button("Importera matchande symbol-XML") { open(.symbols) }
                    if let issue = model.symbolIssue { Text(issue).foregroundStyle(.orange) }
                    ForEach(model.symbols?.warnings ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(results) { symbol in
                    NavigationLink { MapView(model: model, symbol: symbol) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(symbol.name).font(.subheadline.weight(.medium))
                            HStack {
                                Text(String(format: "%06X • %d byte • #%d", symbol.address, symbol.length, symbol.id)).font(.caption.monospaced())
                                Spacer()
                                if !symbol.isEditable { Image(systemName: "lock") }
                            }.foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.searchable(text: $query, prompt: "Sök symbolnamn")
    }
}

struct HistoryView: View {
    @ObservedObject var model: Workspace
    let open: (ImportPurpose) -> Void
    var body: some View {
        List {
            Section {
                Button("Ångra senaste ändringen", systemImage: "arrow.uturn.backward") { model.undo() }.disabled(!model.canUndo)
                Button("Gör om", systemImage: "arrow.uturn.forward") { model.redo() }.disabled(!model.canRedo)
                Button("Jämför med annan BIN-fil", systemImage: "doc.on.doc") { open(.compare) }.disabled(model.session == nil)
            }
            if let name = model.comparisonName {
                Section("Jämförelse: \(name)") {
                    Text("\(model.differences.count) avvikande byteområden. Visar högst 500.")
                    ForEach(Array(model.differences.prefix(500))) { difference in
                        Text(String(format: "%06X–%06X · %d byte", difference.range.lowerBound, difference.range.upperBound - 1, difference.range.count)).font(.caption.monospaced())
                    }
                }
            }
            Section("Ändringshistorik") {
                let history = model.session?.undoStack ?? []
                if history.isEmpty { Text("Inga ändringar ännu.").foregroundStyle(.secondary) }
                ForEach(Array(history.enumerated()).reversed(), id: \.offset) { entry in
                    VStack(alignment: .leading) {
                        Text("Ändring \(entry.offset + 1)").font(.headline)
                        ForEach(Array(entry.element.enumerated()), id: \.offset) { row in
                            Text(row.element.reason).font(.subheadline)
                            Text(String(format: "%06X · %d byte", row.element.address, row.element.after.count)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
