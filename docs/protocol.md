<!-- markdownlint-disable MD013 MD060 -->

# Protokół sterowania przez Ethernet

Opis formatów ramek i sposobu komunikacji z płytką. Listę rejestrów i ich statusy prowadzi `regmap.yaml`. Tabela w sekcji 4 jest generowana z tego pliku przez `tools/gen_regmap.py`.

## 1. Połączenie

- TCP, serwer na płytce, port `5000`, adres `192.168.1.50`.
- Jedno połączenie naraz.
- Pola wielobajtowe są big-endian (najpierw starsze bajety).
- Stan akwizycji nie zależy od połączenia i przetrwa rozłączenie hosta.
- Tryb ciągły (`sw(0) = 1`): protokół jest wyłączony. Płytka nie odpowiada na ramki, a do TCP płynie licznik bajtów. Host powinien to wykryć timeoutem.

## 2. Ramka

Zapytanie i odpowiedź mają zawsze 8 bajtów.

| Bajt | Pole | Opis |
|------|------|------|
| 0-1 | magic | `C7 E2` |
| 2 | komenda | `01` zapis, `02` odczyt. W odpowiedzi bit 7 ustawiony, albo `FF` przy błędzie |
| 3 | adres | adres rejestru |
| 4-7 | dane | wartość, big-endian |

Odpowiedź ma ten sam adres co zapytanie.

### 2.1 Odpowiedzi

| Zapytanie | Odpowiedź (bajt 2) | Dane |
|-----------|--------------------|------|
| zapis `01` | `81` | wartość zapisana, albo `0` dla komend |
| odczyt `02` | `82` | wartość rejestru |
| błąd | `FF` | kod błędu w bajcie 7, bajty 4-6 zerowe |

### 2.2 Kody błędów

| Kod | Nazwa | Kiedy |
|-----|-------|-------|
| `01` | `ERROR_UNKNOWN_COMMAND` | komenda inna niż `01` i `02` |
| `02` | `ERROR_BAD_ADDRESS` | adres nieobsługiwany |
| `03` | `ERROR_READ_ONLY` | zapis do rejestru tylko do odczytu |
| `04` | `ERROR_WRITE_ONLY` | odczyt rejestru tylko do zapisu |
| `05` | `ERROR_BAD_VALUE` | wartość niepoprawna albo niespójna konfiguracja |
| `06` | `ERROR_NOT_READY` | `READ_RECORD` bez gotowego rekordu |

Ramka z błędnym magic nie dostaje odpowiedzi. Płytka pomija bajty, aż zobaczy `C7 E2`.

## 3. Wymiana

- Jedno zapytanie w toku. Po wysłaniu ramki przeczytaj dokładnie 8 bajtów odpowiedzi, dopiero potem wysyłaj następną.
- Płytka nie ma timeoutów. Host ustawia własne, np. 3 s na ramkę.
- Przy błędzie magic, timeoucie albo zerwaniu w środku ramki lub bloku zamknij połączenie i połącz ponownie. Płytka nie resynchronizuje danych bloku.
- Komendy ze statusem `accepted` w `regmap.yaml` zwracają `81` z danymi `0`, ale nic nie robią. Skutku trzeba szukać w stanie układu, nie w odpowiedzi.

## 4. Zaimplementowane rejestry

Lista generowana z `regmap.yaml` (status `implemented`). Opisy uzupełnia się ręcznie, nowe wiersze dostają `---`. Adresy spoza tabeli zwracają `ERROR_BAD_ADDRESS`.
<!-- REGMAP:REGISTERS:BEGIN -->
| Adres | Nazwa | Opis |
|-------|-------|------|
| `0x00` | `ADDR_DEVICE_ID` | Identyfikator urządzenia |
| `0x01` | `ADDR_PROTOCOL_VERSION` | Wersja protokołu, `0x00000001` |
| `0x10` | `ADDR_COMMAND_COMMIT` | --- |
| `0x11` | `ADDR_COMMAND_ARM` | Uzbrojenie akwizycji (IDLE lub READY → ARMED) |
| `0x12` | `ADDR_COMMAND_STOP` | Zatrzymanie akwizycji, powrót do IDLE |
| `0x13` | `ADDR_COMMAND_FORCE_TRIGGER` | Ręczne wyzwolenie z ARMED, start zapisu rekordu |
| `0x15` | `ADDR_COMMAND_CLEAR_COUNTERS` | --- |
| `0x16` | `ADDR_COMMAND_RESET_CONFIG` | --- |
| `0x17` | `ADDR_COMMAND_READ_RECORD` | Pobranie gotowego rekordu: odpowiedź i blok danych |
| `0x31` | `ADDR_ACQUISITION_RECORD_LENGTH` | --- |
| `0x34` | `ADDR_ACQUISITION_CHANNEL_MASK` | --- |
| `0x90` | `ADDR_COUNTER_FRAMES_OK` | --- |
| `0x91` | `ADDR_COUNTER_BAD_MAGIC` | --- |
| `0x92` | `ADDR_COUNTER_UNKNOWN_COMMAND` | --- |
| `0x93` | `ADDR_COUNTER_BAD_ADDRESS` | --- |
| `0xA0` | `ADDR_ACQUISITION_STATE` | Stan akwizycji: 0 IDLE, 1 ARMED, 2 CAPTURE, 3 READY |
| `0xA4` | `ADDR_ACQUISITION_RECORD_ID` | Numer ostatniego kompletnego rekordu |
| `0xF0` | `ADDR_DEBUG_SCRATCH0` | Rejestr roboczy do testu toru |
| `0xF1` | `ADDR_DEBUG_SCRATCH1` | Rejestr roboczy do testu toru |
| `0xF2` | `ADDR_DEBUG_LED` | Bity [7:0] sterują diodami RGB na płytce |
| `0xF3` | `ADDR_DEBUG_CONST` | Stała `0xDEADBEEF` do testu odczytu |
<!-- REGMAP:REGISTERS:END -->

## 5. Odczyt rekordu

Przebieg:

1. Wyślij `ADDR_COMMAND_READ_RECORD` (`C7 E2 01 17 00 00 00 00`).
2. Odpowiedź `81` oznacza, że rekord jest gotowy i nadchodzi blok. Odpowiedź `FF` z `ERROR_NOT_READY` oznacza, że nic więcej nie przyjdzie.
3. Przy `81` przeczytaj dokładnie 64 bajty nagłówka.
4. Sprawdź nagłówek (sekcja 5.1).
5. Przeczytaj dokładnie `PAYLOAD_LEN` bajtów próbek.
6. Wróć do wymiany ramek.

Rekord jest gotowy w stanie READY. Stan odczytuje się z `ADDR_ACQUISITION_STATE`: `0` IDLE, `1` ARMED, `2` CAPTURE, `3` READY. Odczyt rekordu nie zmienia stanu i można go powtarzać, aż do następnego ARM.

### 5.1 Nagłówek (64 bajty)

| Bajt | Pole | Typ | Znaczenie |
|------|------|-----|-----------|
| 0-1 | magic | 2 B | `C7 E2` |
| 2 | typ | 1 B | `D0`, blok danych |
| 3 | flagi | 1 B | bit 0: przesterowanie ADC w trakcie rekordu. Obecnie `00` |
| 4-7 | PAYLOAD_LEN | u32 | długość próbek w bajtach |
| 8-11 | RECORD_ID | u32 | numer rekordu |
| 12 | CHANNEL_MASK | 1 B | maska kanałów w bloku |
| 13 | SAMPLE_BITS | 1 B | bity na próbkę, obecnie `08` |
| 14-15 | zarezerwowane | 2 B | `00` |
| 16-19 | SAMPLES_PER_CH | u32 | liczba próbek na kanał |
| 20-63 | zarezerwowane | 44 B | `00` |

Host sprawdza:

- magic i typ,
- `PAYLOAD_LEN = SAMPLES_PER_CH × liczba_kanałów × SAMPLE_BITS / 8`, gdzie liczba kanałów to 2 dla maski `03`, a 1 dla pozostałych,
- że `RECORD_ID` jest nowy względem poprzedniego odczytu.

Bajty zarezerwowane nie są obecnie wypełniane i w przyszłości mogą zyskać znaczenie. Host nie powinien na nich polegać.

### 5.2 Próbki

| Maska | Układ w bloku | Stan |
|-------|---------------|------|
| `01` | `ch1[0] ch1[1] ...` | używana |
| `02` | `ch2[0] ch2[1] ...` | obsługiwana przez firmware, ch2 = 0 |
| `03` | `ch1[0] ch2[0] ch1[1] ch2[1] ...` | obsługiwana przez firmware, ch2 = 0 |

Próbka to bajt `0x00`-`0xFF`: górne 8 bitów 12-bitowego wyniku przetwornika. Napięcie przybliżone: `U = kod × Vref / 256`.

## 6. Przykłady

Zapis `0x12345678` do rejestru debug `0xF0`:

```
-> C7 E2 01 F0 12 34 56 78
<- C7 E2 81 F0 12 34 56 78
```

Odczyt identyfikatora urządzenia:

```
-> C7 E2 02 00 00 00 00 00
<- C7 E2 82 00 00 00 AB 01
```

Zapis do rejestru tylko do odczytu:

```
-> C7 E2 01 00 00 00 00 01
<- C7 E2 FF 00 00 00 00 03
```

Odczyt adresu zarezerwowanego:

```
-> C7 E2 02 05 00 00 00 00
<- C7 E2 FF 05 00 00 00 02
```

Pobranie rekordu, gdy jest gotowy:

```
1. -> C7 E2 01 17 00 00 00 00
   <- C7 E2 81 17 00 00 00 00
2. <- 64 bajty nagłówka
3. <- PAYLOAD_LEN bajtów próbek
```
