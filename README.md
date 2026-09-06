# T7suite-iOS

Native Swift-omskrivning av centrala delar av **T7Suite 0.1.59.0** för iPhone. Projektet innehåller en plattformsoberoende T7-kärna, ett SwiftUI-gränssnitt, ett Xcode-projekt, tester och en källanalys av de två uppladdade originalarkiven.

> **Utvecklingsversion – inte en komplett ersättare för Windows-versionen.** Filanalys och lokal råvärdesredigering är implementerade. Appen kan ännu inte ansluta till, läsa eller skriva en fysisk ECU. Adapterdrivrutin, sessionsstart, flashning, realtidsdata och autotune återstår. Ingen signerad IPA eller TestFlight-version ingår.

## Dokumentation

| Dokument | Innehåll |
|---|---|
| [Djupanalys](docs/ANALYS.md) | Arkividentitet, installationsjämförelse, originalarkitektur, filformat, symbolkomprimering, checksummor, CAN/KWP och portningsbeslut. |
| [Funktionsmatris](docs/PARITY.md) | Implementerat, delvis implementerat och saknat, inklusive prioritering mot full funktionalitet. |
| [Testprotokoll](docs/TESTING.md) | Faktiskt körda tester, reproduktionskommandon och tydliga verifieringsgränser. |

## Implementerat

**Fil och metadata:** öppna en 512 KiB T7 BIN-fil, läsa footer, programvaruidentitet och symboltabeller; expandera komprimerade symbolnamn och importera programvaru-/adressmatchad XML. Okända eller osäkra adressmappningar gissas inte fram.

**Redigering:** söka symboler, visa råvärden som u8/s8/u16/s16, välja visningskolumner och ändra direktadresserade kalibreringar i en arbetskopia. Atomiska transaktioner, konfliktkontroll, ångra/gör om, bytejämförelse, projektexport och CSV finns. Enheter, axlar och skalor är inte automatiskt verifierade.

**Integritet:** kontroll och reparation av F2, FB och firmwarechecksummor. BIN-export reparerar kontrollsummorna i rätt ordning och verifierar resultatet. Okända format blockerar export. En korrekt checksumma är inte ett bevis för en motorsäker kalibrering.

**Loggar:** import av T7Suite `.t7l`, kanalval, diagram och CSV. Ogiltiga rader redovisas. Grafen är en begränsad översikt och kan missa korta toppar; CSV innehåller alla accepterade rader.

**Protokollkärna:** Saab-specifik KWP-over-CAN-paketering, kvittenser, återmontering, negativa svar och timeoutkontroll. Detta är inte ISO-TP och inte en adapterdrivrutin. Anslutningsflikens lokala ramtest är uttryckligen märkt som testdata utan ECU.

## Öppna i Xcode

På en Mac med Xcode och Swift 6:

```sh
git clone https://github.com/engdahlz/T7suite-IOS.git
cd T7suite-IOS
open T7suite.xcodeproj
```

Välj schemat **T7Suite** och en iPhone-simulator. Appens deployment target är iOS 17.0; exakt provad verktygskedja och simulator framgår av testprotokollet. Projektet har inga externa paketberoenden: `T7Core` hämtas från det lokala Swift-paketet i samma repository.

För installation på en fysisk iPhone behöver appmålet en giltig signeringskonfiguration under **Signing & Capabilities** och ditt Apple-utvecklarteam. Denna leverans innehåller inga certifikat eller provisioning-profiler. Fysisk iPhone och fordonsadapter har inte provats.

## Använd filverktygen

Öppna en egen T7 BIN-fil under **Fil**. Kontrollera metadata och checksummor. Under **Kartor** kan du söka symboler och visa råvärden. Ange datatyp och layout utifrån en verifierad definition; appen avgör inte rätt motorvärden åt dig.

Aktivera lokal redigering bara för en kalibrering du kan identifiera korrekt. Ändringar syns under **Historik**. Spara **projekt med historik** för att kunna fortsätta senare, eller exportera en separat BIN med kontrollerade checksummor. Originalfilen skrivs inte över automatiskt.

**Autosparning finns inte ännu.** Exportera projektet före avslut. `.t7project` är ett nytt, versionsmärkt format och inte en generell importerare för äldre Windows-projekt. Projektet sparar tillämpad historik men inte redo-stacken.

## Tester och kommandoradsverktyg

```sh
swift test --enable-code-coverage
swift run t7inspect /sökväg/till/firmware.bin
```

Den vanliga testsamlingen innehåller 41 testfall: 40 har godkänts och ett privat korpustest hoppas över när originalfirmware saknas. Samtliga 256 firmwarefiler i användarens arkiv har dessutom körts separat genom den optimerade korpuskontrollen. Se [testprotokollet](docs/TESTING.md) för vad detta faktiskt verifierar och för simulatorresultatet.

GitHub Actions kör kärntester och iPhone-grundprov vid kodändringar. Dokumentationsändringar kan använda `[skip ci]`; den senaste dokumentationscommiten behöver då inte ha en egen körning.

## Struktur

```text
Sources/T7Core/        BIN, footer, checksummor, symboler, redigering, dokument, KWP
Sources/T7Inspect/     Skrivskyddad JSON-inspektör
Tests/T7CoreTests/     Syntetiska data, regressioner och protokollreplay
iOS/                  SwiftUI, Filer-import/export och Charts
UITests/              Start, navigation och tydligt lokalt ramtest
T7suite.xcodeproj/     Appmål, UI-testmål och delat schema
Tools/CorpusCheck.swift Optimerad kontroll mot privata firmwarefiler
docs/                 Analys, funktionsmatris och testprotokoll
```

## Nästa tekniska steg

Full funktionalitet kräver först verifierade kartdefinitioner och fler fil-/UI-regressioner, därefter en specificerad iPhone-kompatibel adapter och läsande ECU-funktioner. Skrivande funktioner behöver separata programmerings-, avbrotts- och återställningsprov på en ECU-testbänk. Funktionsmatrisen beskriver även de avancerade kartverktyg och tuningfunktioner som återstår.

## Proveniens och licens

Originalunderlag: `TuningSuites-T7suite_v0.1.59.0.tar.gz` och Windows-installationen `T7Suite (1).zip`. Exakta SHA-256-värden och undersökta versioner finns i analysen. Den nya koden distribueras med [Apache License 2.0](LICENSE) och [NOTICE](NOTICE).

Originalfirmware, Windows-installation, manualer och tredjeparts-DLL:er ingår inte. Deras rättigheter följer inte automatiskt av projektets licens. Projektet är fristående och inte en officiell Saab-, Apple- eller TxSuite-produkt.
