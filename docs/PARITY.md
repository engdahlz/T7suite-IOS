# Funktionsmatris: Windows → iPhone

Status för den första native-porten, 6 september 2026. **Inte full funktionsparitet.** En funktion märkt implementerad avser den specificerade delmängden, inte all Windows-funktionalitet. Faktiskt körda tester redovisas i [TESTING.md](TESTING.md); UI-kod och ett grönt grundprov är inte ett fullständigt test av varje filarbetsflöde.

| Funktion / grupp | Levererad implementation | Begränsning eller återstående arbete |
|---|---|---|
| Öppna T7 BIN | Implementerad kärna + iOS-filimport | Exakt 512 KiB. Ingen generell T5/T8/Motronic-import. |
| Footer / firmwareinformation | Implementerad läsare + vy | Okända/skadade poster repareras inte automatiskt. Ingen VIN-/immobilizerredigering. |
| F2, FB och firmwarechecksumma | Implementerad kontroll och reparation | Okänd rutin blockerar BIN-export. Ingen motorsäkerhetsgaranti. |
| Packad symboltabell | Implementerad | 226 packade filer ingår i den testade korpusen. |
| Opackad symboltabell | Implementerad | 30 opackade filer testade; äldre relokering visas skrivskyddat. |
| Komprimerade symbolnamn | Implementerad, inklusive reskalning | Storleksgräns och strikta fel. Inte generell stödgaranti för okända format. |
| Symbol-XML | Implementerad import | Exakt programvaru-, index- och adressmatchning. Ingen hämtning från webben. |
| Sökning / kalibreringsfilter | Implementerad i UI | Namnklassificering, inte en fullständigt verifierad definitionsdatabas. |
| 8-/16-bitars råvärden, signed/unsigned | Implementerad | Manuellt val. Ingen automatisk enhets-/skalbestämning. |
| Rutnätsredigering | Implementerad för direktadresserade, namngivna kalibreringar | Bekräftad lokal redigering; högst 4 096 värden visas. Omlokaliserade symboler är skrivskyddade. |
| Kartdimensioner | Manuell visningslayout | Automatisk dimensionering och matchade fysiska axlar återstår. |
| Skalor, enheter, offset, axelkoppling | Inte implementerat | Kräver versionsmärkt definitionskatalog och jämförelse med originalet. |
| Kurva | Enkel index–råvärdeskurva | Första 512 värdena; inte full motsvarighet till Windows 2D/3D-verktyg. |
| 3D-yta / kartöverlägg | Inte implementerat | Ingen falsk 3D-funktion i gränssnittet. |
| Multiplikation/addition av flera celler | Implementerat och testat i kärnan | Ännu inte exponerat som flercellsverktyg i UI. |
| Interpolation, smoothing, avancerat urval | Inte implementerat | Kräver definierade axlar, urval och originaljämförelser. |
| Kopiera kartor mellan programversioner | Inte implementerat | Inga automatiska adress- eller skalantaganden. |
| BIN-jämförelse | Implementerad byteintervalljämförelse + vy | Visar högst 500 intervall. Ingen semantisk kartjämförelse. |
| SRAM-jämförelse och snapshot | Inte implementerat | SRAM är inte samma sak som ett 512 KiB BIN. |
| Transaktioner / ångra / gör om | Implementerat och testat | Konfliktkontroll och atomiska ändringspaket. |
| Spara/öppna projekt | Eget versionsmärkt .t7project | Original + tillämpade transaktioner + XML. Äldre Windows-projekt och redo-stack importeras inte. |
| Automatisk sessionsåterställning | Inte implementerat | Använd uttrycklig projektexport; osparat tillstånd kan gå förlorat när appen avslutas. |
| BIN-export | Implementerad och checksumverifierad | Sparar arbetskopia; användaren väljer destination. Ingen ECU-skrivning. |
| Kart-/logg-CSV | Implementerat | Inte Excel COM, XLSX, DIF eller XDF-paritet. |
| T7Suite .t7l-import | Implementerat och testat | UTF-8, tidsstämplar, decimalpunkt/komma; ogiltiga rader redovisas. |
| Loggdiagram | Implementerad kanalöversikt | Högst 1 000 punkter; korta toppar kan missas i grafen men inte i full CSV. |
| CAN-ramtyp | Implementerad | Standard-ID 0…0x7FF, 1…8 byte. Ingen adapterimplementation. |
| Saab KWP-segmentering / ACK / svar | Implementerat och replay-testat | Inte generisk ISO-TP. Inte verifierat på fysisk buss. |
| KWP readIdentifier / testerPresent | Läsande transaktionsmotor | Förutsätter etablerad session och framtida transport; inte ansluten till verklig bil i UI. |
| Adapterval och anslutning | Inte implementerat | Ingen adapter angiven. Windows-drivrutiner har inte portats. |
| Sessionsstart / keepalive-schemaläggning | Inte implementerat | Enstaka testerPresent-anrop finns i kärnan, inte en komplett ECU-session. |
| ECU-identitet / full VIN-diagnostik | Endast lokal footer och replay-data | Verklig läsning och ECU-specifik VIN-tolkning återstår. |
| Läsa/radera felkoder | Inte implementerat | Varken generisk OBD-knapp eller påstått Tech2-stöd. |
| Realtidsdata / mätinstrument | Inte implementerat | Kräver adresser, skalor, samplingsstrategi och adaptertester. |
| SRAM-läsning/-skrivning | Inte implementerat | Inga skrivkommandon exponeras. |
| ECU-backup / flashläsning | Inte implementerat | Kan inte ersättas av filimport; kräver programmeringsprotokoll och återläsningskontroll. |
| Flashning / radering / återställning | Inte implementerat | Kräver adapter, ECU-testbänk, kompatibilitetskontroll och avbrottstester. |
| Säkerhetsåtkomst / seed-key | Inte implementerat | Måste verifieras per stödd ECU och användningsfall. |
| Bredbandslambda / externa ADC-/temperatursignaler | Inte implementerat | Separata Windows-bibliotek och hårdvaruintegrationer. |
| Autotune / AFR-feedback / live-kartskrivning | Inte implementerat | Kräver verifierade mätsignaler, begränsningar och skrivande hårdvarutester. |
| Tuningguider / stage- och luftmasseberäkningar | Inte implementerat | Ska inte förväxlas med råvärdesredigering. |
| Tuningpaket / firmwarepatchar / specialinställningar | Inte implementerat | Programversionsberoende ingrepp behöver individuella testfall. |
| SID, ESP/TCM-relaterade ändringar och aktiveringstester | Inte implementerat | Ingen generell konfigurering av andra styrenheter utlovas. |
| Disassembler / IDA-export / avancerad hexeditor | Inte implementerat | Den begränsade checksumrutinläsaren är inte en disassemblerprodukt. |
| Uppdaterare, Windows-layout och Office-integration | Inte portat | Ersätts inte genom DLL-paketering; plattformsspecifika produktbeslut återstår. |
| Simulator-/UI-grundprov | Xcode-projekt och två XCTest UI-prov | Se testprotokollet för faktisk körstatus. Full filimport/export-UI-regression återstår. |
| Fysisk iPhone / adapter / ECU | Inte testat | Ingen fysisk hårdvara har använts i denna leverans. |
| Signerad IPA / TestFlight / App Store | Inte levererat | Kräver Apple-signering och distributionsarbete. |

## Prioritering mot full funktionalitet

**A. Säkra filverktyg:** verifierade kartdefinitioner, semantisk jämförelse, enheter/axlar, fler redigeringsverktyg, autosparning och fulla UI-filtester. Acceptans: relevanta utdata matchar en oberoende originalkörning och korrupta filer ger kontrollerade fel.

**B. Läsande hårdvara:** en specificerad adapter, sessionsstart, identifiering, felkoder, SRAM och live-loggning. Acceptans: reproducerbara bussinspelningar, samtidighet och avbrott fungerar på testbänk och fysisk iPhone.

**C. Skrivande hårdvara:** backup, programmeringsfaser, läs-tillbaka, återställning och versionsbundna patchar. Acceptans: avbrottsförsök på återställningsbar ECU-testbänk, inte bara normala lyckade förlopp.

**D. Tuning-/produktparitet:** autotune, externa sensorer, avancerade kartor, guider, paketformat, tillgänglighet och distribution. Varje rad måste få eget testbevis innan den ändras till fullständigt stödd.

Detta är en teknisk arbetsordning, inte en tidsuppskattning eller ett löfte om automatiskt fortsatt arbete.
