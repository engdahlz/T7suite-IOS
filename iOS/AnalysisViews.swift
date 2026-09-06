// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Charts
import T7Core

struct MapView: View {
    @ObservedObject var model: Workspace
    let symbol: T7Symbol
    @State private var encoding: CellEncoding = .u8
    @State private var columns = 8
    @State private var values: [Int] = []
    @State private var problem: String?
    @State private var selected: Int?
    @State private var newValue = ""
    @State private var showEdit = false
    private var rowCount: Int { columns > 0 ? (values.count + columns - 1) / columns : 0 }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(symbol.name).font(.title2.bold()).textSelection(.enabled)
                Text(String(format: "Adress %08X • %d byte • symbol %d", symbol.address, symbol.length, symbol.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let note = symbol.addressNote { Label(note, systemImage: "lock").font(.footnote).foregroundStyle(.orange) }
                Text("Råvärden. Välj bytebredd, tecken och kolumner med hjälp av en verifierad definition. Appen gissar inte enheter eller axlar.").font(.footnote).foregroundStyle(.secondary)
                Picker("Datatyp", selection: $encoding) {
                    ForEach(CellEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Stepper("Kolumner: \(columns)", value: $columns, in: 1...32)
                if symbol.isEditable {
                    Toggle("Aktivera lokal kalibreringsredigering", isOn: $model.acknowledgeCalibrationRisk)
                    Text("Felaktiga värden kan skada motorn. Ingen ändring skickas till en ECU.").font(.caption).foregroundStyle(.orange)
                } else { Label("Den här symbolen är skrivskyddad.", systemImage: "lock") }
                if let problem { Text(problem).foregroundStyle(.orange) }
                if !values.isEmpty {
                    Text("\(values.count) värden · \(rowCount) visningsrader").font(.caption)
                    if values.count % columns != 0 { Text("Ofullständig sista rad: detta är en visningslayout, inte en verifierad kartdimension.").font(.caption).foregroundStyle(.orange) }
                    ScrollView(.horizontal) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 4), count: columns), spacing: 4) {
                            ForEach(Array(values.prefix(4096).enumerated()), id: \.offset) { cell in
                                Button {
                                    selected = cell.offset; newValue = String(cell.element); showEdit = true
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(String(cell.element)).font(.body.monospacedDigit())
                                        Text("#\(cell.offset)").font(.caption2).foregroundStyle(.secondary)
                                    }.frame(width: 76, height: 45).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).disabled(!symbol.isEditable || !model.acknowledgeCalibrationRisk)
                                    .accessibilityLabel("Cell \(cell.offset), värde \(cell.element)")
                            }
                        }
                    }
                    if values.count > 4096 { Text("Visar de första 4 096 värdena.").font(.caption) }
                    Chart(Array(values.prefix(512).enumerated()), id: \.offset) { cell in
                        LineMark(x: .value("Index", cell.offset), y: .value("Råvärde", cell.element))
                    }.frame(height: 180).accessibilityLabel("Råvärdeskurva, första 512 cellerna")
                    Button("Exportera råvärden som CSV") {
                        do {
                            guard let address = symbol.flashAddress, let image = model.session?.image else { return }
                            let grid = try MapGrid(bytes: image.read(at: address, count: symbol.length), encoding: encoding, columns: columns)
                            model.exportCSV(grid.csv(), name: symbol.name + ".csv")
                        } catch { model.error = error.localizedDescription }
                    }.disabled(values.count % columns != 0)
                }
            }.padding()
        }
        .navigationTitle("Kartvy").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(encoding.rawValue)-\(model.revision)") { load() }
        .alert("Ändra råvärde", isPresented: $showEdit) {
            TextField("Heltal", text: $newValue).keyboardType(.numbersAndPunctuation)
            Button("Spara i arbetskopian") {
                do {
                    guard let index = selected, let number = Int(newValue.trimmingCharacters(in: .whitespaces)) else { throw T7Error.invalid("Ange ett heltal.") }
                    try model.edit(symbol: symbol, encoding: encoding, index: index, value: number)
                } catch { model.error = error.localizedDescription }
            }
            Button("Avbryt", role: .cancel) {}
        } message: { Text("\(encoding.rawValue): \(encoding.limits.lowerBound)…\(encoding.limits.upperBound). Ändringen går att ångra.") }
    }
    private func load() {
        do {
            guard let address = symbol.flashAddress, let image = model.session?.image else { throw T7Error.unsupported("Symbolen ligger i SRAM eller saknar verifierbar filadress.") }
            values = try encoding.decode(image.read(at: address, count: symbol.length)); problem = nil
        } catch { values = []; problem = error.localizedDescription }
    }
}

struct LogView: View {
    @ObservedObject var model: Workspace
    let open: (ImportPurpose) -> Void
    @State private var channel = ""
    private var selectedChannel: String { channel.isEmpty ? model.log?.channels.first ?? "" : channel }
    var body: some View {
        List {
            Section { Button("Importera T7Suite-logg (.t7l)", systemImage: "doc.badge.arrow.up") { open(.log) } }
            if let log = model.log {
                Section("Mätdata") {
                    LabeledContent("Godkända rader", value: String(log.samples.count))
                    LabeledContent("Avvisade rader", value: String(log.rejectedLines))
                    Picker("Kanal", selection: $channel) {
                        Text("Första kanalen").tag("")
                        ForEach(log.channels, id: \.self) { Text($0).tag($0) }
                    }
                    let strideSize = max(1, (log.samples.count + 999) / 1000)
                    let plot = stride(from: 0, to: log.samples.count, by: strideSize).map { log.samples[$0] }
                    Chart(plot) { sample in
                        if let value = sample.values[selectedChannel] {
                            LineMark(x: .value("Sekunder", sample.elapsed), y: .value(selectedChannel, value))
                        }
                    }.frame(height: 240)
                    Text("Översikten visar högst 1 000 punkter och kan missa korta toppar. CSV innehåller alla godkända rader. Originalets tidszon är inte angiven.").font(.caption).foregroundStyle(.secondary)
                    Button("Exportera loggen som CSV") { model.exportCSV(log.csv(), name: "T7-logg.csv") }
                }
                if !log.warnings.isEmpty {
                    Section("Importvarningar, högst 100") { ForEach(log.warnings, id: \.self) { Text($0).font(.caption) } }
                }
                Section("Senaste värden, högst 100") {
                    ForEach(Array(log.samples.suffix(100))) { sample in
                        LabeledContent(sample.timestamp, value: sample.values[selectedChannel].map { String($0) } ?? "—").font(.caption.monospacedDigit())
                    }
                }
            } else {
                ContentUnavailableView("Analysera en inspelad logg", systemImage: "waveform.path.ecg", description: Text("Importerar T7Suites tidsstämplar och name=value-format. Ingen realtidsanslutning aktiveras."))
            }
        }
    }
}

struct ConnectionView: View {
    @State private var transcript: [String] = []
    var body: some View {
        List {
            Section {
                Label("Ingen bil är ansluten", systemImage: "cable.connector.slash").font(.headline)
                Text("Adapterdrivrutin, sessionsstart och ECU-validering återstår. Den här versionen kan inte läsa eller skriva din ECU.")
            }
            Section("Vad som redan finns i koden") {
                Text("Saabs KWP-over-CAN-ramformat, segmentering, kvittenser, svarskontroll, timeout och en skrivskyddad transaktionsmotor för en redan etablerad session.")
                Text("Det är inte samma sak som generiskt ISO-TP/UDS eller stöd för valfri OBD-adapter.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Lokalt protokolltest") {
                Text("Följande test använder en fördefinierad ramsekvens. Det kommunicerar inte med en bil och bekräftar inte adapterstöd.").font(.footnote)
                Button("Kör ramtest", systemImage: "checkmark.shield") { runTest() }.accessibilityIdentifier("runProtocolTest")
                ForEach(Array(transcript.enumerated()), id: \.offset) { entry in Text(entry.element).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Section("Skrivoperationer är inte implementerade") {
                Text("Flashning, SRAM-skrivning, radering av felkoder, aktiveringstester, säkerhetsupplåsning och autotune måste införas tillsammans med en specificerad adapter och tester på en separat ECU-testbänk.")
            }
        }
    }
    private func runTest() {
        do {
            let request = try KWPCodec.request(service: 0x1A, parameters: [0x90])
            var assembler = KWPAssembler()
            let reply = try CANFrame(id: 0x258, data: [0xC0,0xBF,3,0x5A,0x90,7,0,0])
            guard let result = try assembler.accept(reply), let payload = result.payload else { throw T7Error.invalid("Lokalt test saknar svar.") }
            let data = try KWPCodec.positive(payload, for: 0x1A, echo: [0x90])
            transcript = ["TESTDATA – ingen ECU", "TX " + request[0].hex, "RX " + reply.hex, "ACK " + result.ack.hex, "Avkodat testsvar: \(data)", "Ramtest godkänt."]
        } catch { transcript = [error.localizedDescription] }
    }
}
