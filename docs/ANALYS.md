# T7Suite 0.1.59.0 → iPhone: källanalys och portningsbeslut

**Granskad leverans: 6 september 2026.** Underlaget är användarens två uppladdade arkiv, kompletterat med TxSuites officiella webbplats, originalprojektets källkod och Apples utvecklardokumentation. Detta är en inventering av hela arkiven och en närläsning/omskrivning av centrala dataflöden, inte ett påstående att varje Windows-funktion har körts eller att varje kodrad är formellt verifierad.

## 1. Vad de två arkiven faktiskt innehåller

| Underlag | Innehåll | Betydelse för portningen |
|---|---|---|
| `TuningSuites-T7suite_v0.1.59.0.tar.gz` | 2 968 arkivposter, 2 843 vanliga filer, 342 648 099 byte i vanliga filer; 855 C#-filer och 26 C#-projekt | Ett utvecklararkiv, inte bara T7-programmet. Även andra generationer och delade bibliotek ingår. |
| `T7Suite (1).zip` | `setup.exe`, `T7Suite.msi`, `T7Suite.md5` | Windows-installation, inte ett andra fristående källkodsprojekt. MSI-tabeller och dess CAB-innehåll har lästs utan att köra installationen. |

SHA-256 för källarkivet: `78c688d0703ec20dc30e46253e117943c28d1beedbd3707dcc7c2a03c5e74978`.

SHA-256 för ZIP-arkivet: `f4b129e9da6a2b26ef1fff714f8cd5a706af23fbafe7ba281d48fc88ffa1e612`.

Installationspaketets produktversion är **0.1.59** och den installerade `T7.exe` anger **0.1.59.0**. MSI-payloaden innehåller 77 filer. Det medföljande MD5-värdet överensstämmer med MSI-filen; MD5-matchningen är endast en jämförelse med den medföljande kontrollfilen, inte ett äkthetsintyg.

| Viktig installerad komponent | Version | Storlek | Observation |
|---|---:|---:|---|
| `T7.exe` | 0.1.59.0 | 4 759 040 byte | Windows-programmet. SHA-256 `f38b88176fadd0c4e0568f13c032feb8ba9efd61788843df40298087d142f902`. |
| `TrionicCANLib.dll` | 0.1.55.0 | 308 736 byte | Byteidentisk med biblioteket i källarkivet. SHA-256 `cb9a067379516a0d82c3ada673c062d6d5f05774024a679a0be148f0cb04b320`. |
| `WidebandSupport.dll` | 1.0.4.0 | 33 280 byte | Byteidentisk kopia finns i källarkivet. Bredbandslambda är ett separat beroende, inte bara en graf i huvudprogrammet. |
| `CommonSuite.dll` | 1.0.15.0 | Se installationsmanifestet | Delad programlogik och Windows-kontroller. |

Totalt matchar 16 av installationspayloadens filer någon källarkivsfil exakt. Detta betyder inte att alla övriga filer är funktionellt olika: kompilerade filer kan inte jämföras direkt med sina källor, och XML kan skilja sig i exempelvis serialisering. Några XML-filers hash skiljer sig mellan paketen; ingen semantisk likvärdighet för dessa hävdas här.

**Slutsats:** omskrivningen ska utgå från källkodens beteende och kontrolleras mot installationens versioner och data. Att paketera `T7.exe` eller dess DLL-filer i en iPhone-app återskapar inte deras Windows-miljö.

## 2. Originalets arkitektur

Det aktuella T7-projektet är `T7Suite/T7.csproj`, med .NET Framework 4.0 och x86-konfiguration. Gränssnittet använder Windows Forms och DevExpress 11.2. Även Nevron-grafik, Excel/Office-interoperabilitet och hårdvaruspecifika bibliotek förekommer.

| Del | C#-filer | Rader, inklusive genererad kod och texter | Ansvar |
|---|---:|---:|---|
| `T7Suite` | 126 | 111 265 | Fönster, kartor, projekt, filöppning, loggar, realtidsflöden och sammanbindande logik. |
| `CommonSuite` | 97 | 24 917 | Symboler, komprimering, loggformat och delade komponenter. |
| `T7CANFlasher` | 29 | 8 606 | Äldre T7-fil- och KWP/CAN-implementationer. |

`T7Suite/frmMain.cs` är 19 163 rader. `SymbolTranslator.cs` är 34 491 rader och innehåller stora mängder symbolbeskrivningar. Radantal är därför inte samma sak som mängd oberoende algoritmer. `SymbolAxesTranslator.cs` kopplar kartor till axlar och presentation.

Det centrala flödet är:

```text
BIN-fil → firmwaremetadata → symbolnamn + adressregister
        → kartbytes → datatyp + dimensioner + axlar + skalning
        → redigering → ändringshistorik → checksummor → sparad fil

Adapter → CAN/KWP-session → ECU-tjänster → SRAM-värden
        → skalning → instrument/logg → eventuella skrivoperationer
```

Filredigering och ECU-kommunikation är olika subsystem. Den officiella TxSuite-sidan skiljer också mellan T7Suite som kart-/programredigerare och Trionic CAN Flasher för läsning och skrivning av styrenheter. En port behöver båda dataflödena för motsvarande användarnytta, men ett lyckat BIN-test bevisar inte CAN-kommunikation. [W1]

## 3. BIN-format och footer

T7-filerna i detta underlag är **0x80000 = 524 288 byte**. Den nya `T7Image` accepterar exakt den storleken. Ett korrekt filmått är bara ett första strukturellt villkor, inte bevis för rätt bil eller motor.

Metadata ligger i poster som läses bakifrån i slutet av filen. En post består fysiskt av `data | identifierare | längd`. Läsaren måste därför skilja mellan fysisk byteordning och logiskt innehåll. ASCII-texter lagras baklänges. Numeriska fält har inte en enda gemensam endian-regel:

| ID | Innebörd i de granskade läsarna | Fysisk tolkning |
|---|---|---|
| 0x90 | VIN | Omvänd ASCII. |
| 0x94 / 0x95 | Artikelnummer / programvara | Omvänd ASCII. |
| 0x9B / 0x9C | Symboltabellsinformation / SRAM-offset | Big-endian heltal. |
| 0xF2 / 0xFB | Globala checksummor | Little-endian i footerposten. |
| 0xFE | Firmwarelängd | Little-endian. |

En generisk läsare som vänder varje fält likadant ger alltså fel adresser trots att texten ser korrekt ut. Referens: `T7CANFlasher/T7FileHeader.cs` och den separata Trionic-bibliotekskoden. Den nya läsaren avvisar dubbla identifierare, nollängder, utanförliggande poster och saknad avslutning. Den gör ingen automatisk footerrekonstruktion.

Metadata som VIN eller immobilizer-ID skrivs inte om av gränssnittet. Arbetskopian och originalet är separata. Importen kör inte firmwarekod eller Windows-installationskod.

## 4. Symboltabeller och komprimering

En symbol är inte bara ett namn. Den behöver ett stabilt index, minnesadress, längd och typinformation. Ett namn från en annan programvaruversion kan peka på helt andra bytes.

### Packat format

`T7Suite/Trionic7File.cs` lokaliserar den packade adressinformationen via en signatur. Adressposterna är tio byte långa och avslutas med markören `SC`. Namnströmmen hämtas från separat adress/längdinformation. Namnen expanderas och kopplas till adressposter i ordning.

`CommonSuite/TrionicSymbolDecompressor.cs` kombinerar adaptiv Huffman-avkodning och LZ-liknande bakåtreferenser. De fyra första byten anger expanderad längd i little-endian; bitströmmen läses mest signifikanta bit först. Resultatet innehåller CRLF-separerade namn.

Swift-omskrivningen har instanslokalt träd, begränsad utdata, kontrollerade bakåtreferenser och explicita fel vid avbruten ström. Originalets kommenterade, oprövade reskalningsgren har ersatts med reskalning som behåller löv och bygger om föräldralänkar. Trädinvarianter och en 40 000-symbolers sekvens testas; detta kompletterar, men ersätter inte, korpustesternas verkliga komprimerade strömmar.

Två viktiga fynd uppstod först när alla firmwarefiler provades:

- **116 filer har en sista adresspost utan motsvarande inbyggt namn.** Den behålls med sitt index och görs skrivskyddad. Att flytta namn ett steg hade kunnat ge fel kartadresser.
- **7 filer saknar användbara inbyggda namn.** Dessa får neutrala `Symbolnumber N`, inte namn gissade från en närliggande version. Importerad XML måste matcha programvarusträng, symbolindex och adress.

### Opackat format och SRAM

Den äldre varianten har läsbara, nollavslutade namn och ett adressregister med fjorton byte per post. Källkodens äldre SRAM-/flash-relokering är inte samma sak som en vanlig filadress. Den nya läsaren kan identifiera vissa sådana relationer, men visar omlokaliserade kartor **skrivskyddat** tills en specifik programvaruprofil är verifierad.

Originalets heuristik för att fylla i en skadad/nollställd adress utifrån en föregående post har inte kopierats. Ett tyst gissat adressvärde är olämpligt i en redigerare. Inte heller reduceras godtyckliga ECU-adresser modulo filstorleken.

**Bevisgräns:** 256/256 filer får en strukturellt accepterad symboltabell. Det bevisar inte att varje kartas fysikaliska betydelse, axel eller skrivbarhet är oberoende validerad.

## 5. De tre checksumfamiljerna

Referensen för den separata checksumimplementationen är `TrionicCANLib/Checksum/ChecksumT7.cs` i Trionic-projektet; hämtad blob-SHA är `fe6878ee1089b01271aad04be45a95868ed494e5`. Den hämtade källan är inte automatiskt samma revision som installationspaketets DLL. Kompatibilitet har därför också testats mot de uppladdade firmwarefilerna. [W2]

### FB: summering

32-bitars big-endian ord summeras med definierad omslagning modulo 2³². Eventuella återstående en till tre byte summeras först i en **8-bitars** ackumulator. Det är lätt att skapa en till synes rimlig men inkompatibel port genom att summera dessa restbyte direkt i 32 bitar.

### F2: XOR-baserad summering

Varje big-endian ord XOR:as med en post i en tabell med åtta konstanter. Indexet börjar på **1**, inte 0, och återgår till 0 efter 7. Summan XOR:as därefter med `0x40314081` och minskas med `0x7FEFDFD0`, med 32-bitars omslagning. F2 med värde noll eller frånvarande fält behandlas som inaktiverad enligt den granskade implementationen; det visas inte som en beräknad matchning.

### Firmware: områden från 68000-kod

En maskad signatur lokaliserar checksumrutinen. En begränsad avkodare tolkar mönster för basadress, områdeslängd, absolut/relativ adress och adressen för lagrad kontrollsumma. Det är inte en generell 68000-emulator. Okänd rutin, självinkluderande checksumområde eller adress utanför filen ger ett uttryckligt fel.

**Skrivordningen är viktig:** den nya exporten räknar och skriver firmwarekontrollsumman först, räknar därefter F2/FB över den uppdaterade kopian och läser sedan tillbaka samtliga aktiva kontroller. Detta undviker att globala summor räknas före en ändring som de själva täcker. En redan korrekt fil ska vara byteidentisk efter reparation; det har kontrollerats på hela korpusen.

En korrekt checksumma visar endast intern dataintegritet. Den verifierar inte laddtryck, tändning, blandning, hårdvarukompatibilitet eller motorsäkerhet.

## 6. Kartredigering: vad som krävs utöver bytes

Originalets kartpresentation hämtar dimensioner, axelnamn och skalor från flera platser. Relevanta ingångar är `frmMain.cs` kring matrismått (cirka rad 6431), korrektionsfaktor (6583), 16-bitarsidentifiering (6632), samt `SymbolAxesTranslator.cs` och `SymbolTranslator.cs`. Radnummer avser det uppladdade källarkivet.

En del skalinformation tolkas ur beskrivningstext, bland annat formuleringen `Resolution is `. Att göra denna fria text till den nya appens auktoritativa databas skulle behålla ett skört beroende mellan språk och numerisk tolkning.

Den levererade redigeraren visar därför **råvärden** med uttryckligt val av u8/s8/u16/s16 och visningskolumner. Värden kontrolleras mot datatypens gränser. Ett kolumnantal är inte ett påstående att rätt fysiska axel har hittats. CSV av en kartmatris kräver fullständiga rader. En namngiven kalibrering med direkt, giltig filadress kan redigeras lokalt efter aktivering; namnklassificeringen är inte en motorsäkerhetsvalidering.

`EditSession` genomför ett helt ändringspaket mot en kopia. Varje patch innehåller adress, förväntade gamla bytes, nya bytes och en beskrivning. Överlappande ändringar, längdförändring eller konflikt stoppar hela transaktionen. Ångra/gör om använder samma kontroll. Originalet ändras inte automatiskt.

För full kartparitet behövs en versionerad definitionskatalog med programvaruidentitet, symbolindex, adresser, datatyp, axelreferenser, enhet, faktor, offset och beviskälla. Definitionerna måste testas mot originalet; godtyckliga kartor får inte ärva skalor enbart på liknande namn. Automatisk axelkoppling, 3D-vy, interpolation, tuningpaket och tuningguider är ännu inte portade.

## 7. Projekt och loggar

Det nya projektformatet `.t7project` är versionsmärkt JSON. Det innehåller originalfilen, tillämpade transaktioner och eventuell matchad symbol-XML. Återställning återspelar gamla-byte-villkoren. Det ger spårbarhet och ångra efter återöppning, men är **inte** en importerare för samtliga äldre Windows-projektformat. Redo-stacken sparas inte. Automatisk återställning efter att iOS avslutat appen är inte implementerad; spara projektet uttryckligen.

T7Suites loggskrivare i `frmMain.cs` använder tidsstämpel följd av `|namn=värde|`. Decimaltecknet kan bero på lokal inställning. Den nya läsaren accepterar komma eller punkt, men inte tvetydiga blandningar, NaN eller oändlighet. Felaktiga rader avvisas och räknas; de blir inte nollvärden som skulle förvränga grafen.

Tidsstämplarna innehåller ingen tidszon. UTC används internt endast som stabil koordinat för förfluten tid, inte som påstående om när loggen faktiskt spelades in. Bakåtgående tid avvisas. CSV innehåller samtliga accepterade rader och skyddar farliga kanalnamn från att tolkas som kalkylbladsformler.

Grafen visar en begränsad översikt, högst 1 000 punkter. Den kan missa korta toppar. En produktionsversion för felsökning bör i stället använda en min/max-bevarande nedprovning och kunna zooma till full upplösning. Realtidsinspelning och bredbandslambdaadapter ingår ännu inte.

## 8. ECU-kommunikation: inte generisk OBD

`T7CANFlasher/KWP/KWPCANDevice.cs` visar ett Saab-specifikt KWP-over-CAN-flöde. Att endast implementera standard-ISO-TP/UDS eller generiska OBD-PID:er återger inte detta beteende.

| Riktning | CAN-ID | Central struktur |
|---|---:|---|
| Förfrågan | 0x240 | Ramhuvud, 0xA1, upp till sex nyttobyte. KWP-längd och tjänst ligger i början av nyttolasten. |
| ECU-svar | 0x258 | Förstaram 0xC0, följande 0x80, båda med nedräknande radantal och 0xBF. |
| Kvittens | 0x266 | `40 A1 3F (80 | återstående rader) 00 00 00 00`. Även sista svarsraden kvitteras. |
| Sessionsstart | 0x220 / 0x238 | Separat startutbyte i originalet; inte implementerat i denna leverans. |

`CAN.swift` implementerar paketering, återmontering, sekvenskontroller och svarsmatchning. Negativa svar måste ha rätt tjänst; `0x78` hanteras som ett väntande svar inom mottagningsfristen. En session kan inte köras parallellt med sig själv. Efter timeout eller fel stängs den, eftersom ett försenat svar annars kan förväxlas med nästa transaktion.

**Viktig begränsning:** `KWPReadSession` förutsätter redan etablerad transport/session. `CANTransport` är ett gränssnitt, inte en Bluetooth- eller Wi-Fi-drivrutin. Dess framtida implementation måste själv garantera begränsad, avbrytbar `send`, `receive` och `close`; mottagningsfristen i sessionen kan inte rädda en drivrutin som hänger i `send`. De nuvarande replay-testerna bevisar ramlogik, inte verkliga busstider eller radioförbindelse.

Appen erbjuder varken ECU-läsning, felkodsradering, säkerhetsupplåsning, SRAM-skrivning eller flashning. Det lokala ramtestet är uttryckligen märkt testdata och simulerar inte att en bil är ansluten.

## 9. Varför native Swift och vad adaptervalet innebär

Den nya kärnan är ett Swift 6-paket utan tredjepartsberoenden. SwiftUI och Charts används för iPhone-vyerna. Därmed kan fil- och protokollalgoritmer testas separat från UI och hårdvara. Ingen Windows-DLL, Excel-installation eller DevExpress-runtime krävs för den nya koden.

Detta är ett konstruktionsval, inte ett påstående att alternativa språk eller ramverk är omöjliga. Att återanvända all Windows-kod via en tunn app-wrapper skulle däremot fortfarande lämna gränssnitt, drivrutiner och plattformsberoenden olösta.

Apple tillhandahåller bland annat Core Bluetooth och External Accessory. Vilket gränssnitt som går att använda beror på det faktiska tillbehörets protokoll och tillverkarens stöd. En adapter som stöds av Windows-versionen blir inte automatiskt tillgänglig för iPhone. Ingen generell utfästelse om USB, Bluetooth Classic, BLE eller en viss OBD-adapter görs här. [W3, W4]

Nästa adapterimplementation behöver dokumenterade kommandon, rå CAN-åtkomst på rätt buss, buss-/filterinställningar, felrapporter, mottagningsköer, kvittenstid, kopplingsidentifiering och avbrottsbeteende. En Wi-Fi-brygga eller dokumenterad BLE-adapter kan bedömas först när den är specificerad. Lokal nätverks- eller Bluetooth-behörighet ska läggas till samtidigt med den faktiska implementationen, inte för en låtsasanslutningsskärm.

## 10. Kvalitetsgrindar för återstående arbete

**Filverktyg:** jämför namntabeller, kartadresser, enheter och redigerade utdata mot en oberoende originalkörning. Lägg till korrupta och ovanliga firmwarevarianter samt fuzzning av parsers. Korpustesterna är ett bra regressionsunderlag, inte ett bevis för alla T7-versioner.

**Läsande ECU-funktioner:** börja med en separat ECU-testbänk, verifierad strömförsörjning och känd adapter. Spela in både förfrågningar och svar. Testa identitet, sessionsstart, tester-present, felkoder, SRAM och loggning var för sig. Kontrollera radiobortfall, tappade/dubbla ramar, bakgrundsläge och återanslutning.

**Skrivande ECU-funktioner:** implementera inte genom att bara koppla en knapp till ett generiskt skicka-kommando. Kräv kompatibel firmwareidentitet, backup, konsekvent strömförsörjning, dokumenterad återställningsväg, fasindelad programmering och läs-tillbaka-verifiering. Testa avbrott på en återställningsbar testbänk. Återanslutning får inte automatiskt återuppta en delvis okänd raderings-/programmeringsfas.

**iPhone-produkt:** testa importer/exporter med Filer och molnleverantörer, mörkt/ljust läge, stora textstorlekar, VoiceOver, rotation, minnestryck, stora loggar och avbruten app. Simulatorprov är inte test av fysisk adapter. TestFlight/App Store, ikon, signering, autosparning och full användbarhetsgranskning återstår utöver själva källkoden.

## 11. Licens och proveniens

Källarkivets rotlicens är Apache License 2.0. Den följer med projektet tillsammans med ett NOTICE som anger originalprojekt, omskrivna områden och ändringar. Enskilda tredjepartsdelar måste fortfarande granskas separat. Exempelvis har originalets `CommonSuite/BitStream.cs` en egen licenstext; den nya bitläsaren är en separat implementation.

Windows-installationen, originalfirmware, manual-PDF:er, DevExpress-/Nevron-/adapter-DLL:er och andra leverantörsbinärer distribueras inte i detta repo. Den separata Trionic-källans licensomfattning behöver klarläggas innan mer kod eller DLL:er därifrån tas in. Att en fil kan hämtas offentligt räcker inte som generell licens för all medföljande tredjepartskod.

## Referenser

**Lokala primärkällor:** de två arkiven identifierade med SHA-256 ovan; filvägar och radnummer i denna rapport avser källarkivet. Installationsmetadata kommer från läsning av MSI-tabeller och CAB-payload. Inga påståenden bygger på att installationen körts.

- [W1] TxSuite: https://txsuite.org/ — produktbeskrivningar för T7Suite och Trionic CAN Flasher.
- [W2] Trionic: https://github.com/mattiasclaesson/Trionic — särskilt `TrionicCANLib/Checksum/ChecksumT7.cs`, blob angiven ovan.
- Originalprojekt: https://github.com/mattiasclaesson/TuningSuites — kontrollkälla; användarens arkiv är versionsankaret för denna port.
- [W3] Apple Core Bluetooth: https://developer.apple.com/documentation/corebluetooth
- [W4] Apple External Accessory: https://developer.apple.com/documentation/externalaccessory

Se även [funktionsmatrisen](PARITY.md) och [testprotokollet](TESTING.md). Status ska läsas där, inte härledas från att en klass eller knapp råkar finnas i koden.
