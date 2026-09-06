# Testprotokoll och verifieringsgränser

**Datum: 6 september 2026.** Testresultat avser den nya Swift-implementationen. Originalets Windows-program har inte installerats/körts i denna miljö. MSI/CAB och källkod har analyserats som data.

## 1. Genomförda kärntester

| Miljö | Kommando | Resultat |
|---|---|---|
| Linux x86_64, Swift 6.2.1 | `swift test --enable-code-coverage` | 41 testfall upptäckta; **40 godkända, 1 överhoppat, 0 fel**. |
| GitHub Actions, macOS arm64, Apple Swift 6.3.3 / Xcode 26.6 | Samma kommando | **40 godkända, 1 överhoppat, 0 fel** i de granskade körningarna. |

Det överhoppade testet är `testPrivateFirmwareCorpus`: det kräver miljövariabeln `T7_CORPUS` och privata firmwarefiler som inte distribueras i repot. Detta innebär inte att korpusen lämnades otestad; den kördes separat med det optimerade verktyget enligt nästa avsnitt.

Testfallen täcker byteordning och gränskontroller, korrupt footer, F2-testvektor, FB-omslagning och restbyte, firmwarechecksumma, reparationsordning, inaktiverad F2, heltalsgränser, atomiska karttransaktioner, konflikt/överlapp, ångra/gör om, projektsåterställning, bytejämförelse, loggimport, decimaltecken, felaktiga rader, CSV-formelnamn, XML-matchning och externa entiteter.

Komprimeringstesterna omfattar avbruten/felaktig indata, begränsad utdata, Huffman-trädets invarianter och en sekvens med 40 000 literaltecken som tvingar fram reskalning. Denna encoder och decoder delar trädimplementation, så roundtrip-testet är inte i sig ett oberoende bevis för algoritmen. Verkliga komprimerade symbolströmmar ingår även i korpustestet.

CAN/KWP-testfallen använder **konstruerade ramsekvenser**, inte en inkopplad bil. De omfattar förfrågningsgränser, VIN-liknande testsvar, kvittenser, felaktig ordning, längdfel, negativa svar, väntande svar och timeout som ogiltigförklarar sessionen. De bevisar inte verkliga buss- eller radiotider.

## 2. Separat test mot 256 firmwarefiler

Samtliga `.bin`-filer i det uppladdade källarkivets `T7Binaries` provades med `Tools/CorpusCheck.swift` och optimerad kompilering. Körningen avslutades med exitkod **0** och **256 JSON-rader**.

| Kontroll | Resultat |
|---|---:|
| Ursprungliga aktiva checksummor stämmer | 256 / 256 |
| Reparation av redan korrekt fil ger byteidentisk fil | 256 / 256 |
| Symboltabellen kan parsas och är inte tom | 256 / 256 |
| Avsiktlig enbitsändring i ett firmwarekontrollerat område upptäcks | 256 / 256 |
| Ändrad kopia kan repareras och klarar samtliga aktiva kontroller | 256 / 256 |

Korpusens fördelning: **226 packade och 30 opackade** symboltabeller; **249 filer med inbyggda namn och 7 utan**. I **116 filer** behålls en avslutande adresspost utan namn som skrivskyddad. Symbolantalet varierar från 3 740 till 4 666 per fil; summan är 1 118 088 symbolposter över alla filer, inte lika många unika symboler.

Resultatfilen `corpus-final.jsonl` har SHA-256:

```text
9afff4848e48cc78ff4ab1465d065c94d28ed6336a5f0d524cbb50cfeabe5e4e
```

Den maskinläsbara resultatfilen kan ingå i leveransens evidenspaket, men själva firmwarefilerna distribueras inte. En reparation som godkänns av samma implementation kan innehålla gemensamma fel; därför är matchning mot oförändrade originalfiler särskilt viktig. Nästa kvalitetssteg är också oberoende jämförelse med originalprogrammets genererade utdata.

**Begränsning:** dessa kontroller verifierar inte varje symbols fysiska betydelse, samtliga adresser, rätt motorvariant eller säkra kalibreringsvärden. Att 256 givna filer fungerar är inte en garanti för alla T7-filer.

## 3. Xcode och iPhone-grundprov

Projektet innehåller ett delat schema `T7Suite`, ett iPhone-appmål och två XCTest UI-prov. Proven gäller start/navigation i tomt tillstånd samt anslutningsskärmens uttryckligen lokala ramtest. De täcker inte hela filimport-/redigerings-/exportflödet.

Två faktiska byggfel hittades och åtgärdades under CI:

- Körning `34029355058`: appen försökte bygga både arm64 och x86_64 medan paketet byggdes för vald arm64-simulator. Debug använder nu `ONLY_ACTIVE_ARCH=YES`.
- Körning `34029613730`: Swift rapporterade att `LoadedFirmware` fångade delvis initierat `self` i en closure. Initieringen använder nu en lokal footer och ett uttryckligt XML-villkor.

Korrigeringarna finns i kodcommit **`68a5e5e324c82f5f61961dfb036cf2b6bbf9f691`** och dess föregångare. Den efterföljande körningen är [GitHub Actions 34030009684](https://github.com/engdahlz/T7suite-IOS/actions/runs/34030009684).

**Senast observerad status:** kärntesterna i denna körning har godkänts. Steget för iPhone-bygge och UI-prov pågår fortfarande vid denna protokollversion; ett godkänt simulatorresultat hävdas därför inte här.

Den tidigare granskade runnern använde Xcode 26.6 (17F113) och en iPhone 17 Pro-simulator med iOS 26.4.1. Workflow väljer en tillgänglig iPhone från runnern, inte ett fast simulator-ID. Projektets lägsta deklarerade iOS-version är 17.0; detta är inte samma sak som att iOS 17 har körtestats.

## 4. Reproducera

Från repositoryts rot:

```sh
swift test --enable-code-coverage
swift run t7inspect /sökväg/till/egen-firmware.bin
```

För en privat katalog med firmware:

```sh
swiftc -O -whole-module-optimization Sources/T7Core/*.swift \
  Tools/CorpusCheck.swift -o /tmp/t7-corpus
/tmp/t7-corpus /sökväg/till/T7Binaries > corpus-final.jsonl
```

Alternativt kan det privata XCTest-fallet aktiveras med `T7_CORPUS=/sökväg/till/T7Binaries swift test`. Den redovisade korpuskörningen gjordes med det fristående optimerade verktyget, inte genom att hävda att det överhoppade standardtestet hade körts.

På Mac, välj ett tillgängligt simulator-ID från `xcrun simctl list devices available`:

```sh
xcodebuild -project T7suite.xcodeproj -scheme T7Suite \
  -destination 'platform=iOS Simulator,id=DITT-SIMULATOR-ID' \
  CODE_SIGNING_ALLOWED=NO test
```

## 5. Inte verifierat eller inte implementerat

Ingen fysisk iPhone, adapter eller ECU har använts. Det finns ingen verifierad sessionsstart, fordonsidentifiering, felkodsläsning, SRAM-läsning, flashläsning, flashskrivning, återställning eller autotune i appen. `CANTransport` är ett protokollgränssnitt, inte en hårdvarudrivrutin.

Fullständiga filarbetsflöden i iOS Filer, molnleverantörer, stora textstorlekar, VoiceOver, minnestryck, bakgrundsläge och avbrutna exporter behöver fortfarande systematiska UI-prov. Autosparning, fulla kartdefinitioner, fysisk iPhone-signering, Release-arkivering och distribution har inte godkänts av denna testsamling.

Källkoden har gränskontroller och negativa tester, men en systematisk fuzzkampanj och en oberoende säkerhetsgranskning har inte genomförts. Kodtäckning kan genereras med kommandot ovan; inget påstående om 100 procents täckning görs.

Alla dessa gränser gäller även om en framtida CI-körning blir grön. Ett godkänt grundprov är inte likvärdigt med full funktionsparitet eller motorsäkerhet. Se [funktionsmatrisen](PARITY.md).
