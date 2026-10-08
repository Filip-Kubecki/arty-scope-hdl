<!-- markdownlint-disable MD013 MD060 -->

# Protokół sterowania i mapa rejestrów

**Status:** szkic. Podjęte decyzje są zebrane w sekcji 11, a kwestie nierozstrzygnięte w sekcji 12. Elementy oznaczone *(propozycja)* nie są jeszcze zatwierdzone.

## 1. Opis ogólny

Oprogramowanie hosta (aplikacja sterująca, skrypty testowe lub dowolne narzędzie TCP) konfiguruje FPGA, odczytuje jego stan i pobiera zebrane przebiegi przez jedno połączenie TCP z rdzeniem FC1002_MII. Sterowanie to prosty schemat zapytanie-odpowiedź ze stałymi ramkami po 8 bajtów, a każde zapytanie dostaje dokładnie jedną odpowiedź. Przebiegi są przesyłane tym samym połączeniem w postaci bloków opisanych w sekcji 9.

Zasady projektowe:

- FPGA udostępnia **surowe wartości sprzętowe** (słowo wzmocnienia, kod DAC, poziom wyzwalania w jednostkach ADC). Przeliczanie na jednostki użytkownika (V/div, pozycja) odbywa się po stronie hosta, na podstawie danych kalibracyjnych.
- **Nieużywane bity** w każdym rejestrze: w ich przypadku zapis jest ignorowany, odczyt zawsze zwraca `0`. Dzięki temu można później dodawać nowe pola bez psucia starszych aplikacji.
- **Nieistniejące adresy** zwracają błąd. Nigdy nie zwracają `0`, bo `0` wygląda jak poprawna wartość i ukrywa pomyłki.
- Mapa rejestrów jest zdefiniowana w **jednym pliku źródłowym**, z którego generowany jest pakiet VHDL i stałe po stronie hosta, żeby obie strony nie rozjechały się.
- Dane przebiegów są przesyłane w postaci **surowej**: jeden nagłówek na rekord, a po nim ciągły strumień próbek bez nagłówków w środku.

## 2. Transport

- TCP, rdzeń FC1002_MII w trybie serwera, stały adres IP, bez DHCP.
- Domyślny adres i port: `192.168.1.50:5000` (generyki `G_IP` i `G_PORT`).
- Wszystkie pola wielobajtowe są **big-endian** (najstarszy bajt pierwszy), zgodnie z kolejnością bajtów w `tcp_link`.
- TCP jest strumieniem bajtów bez granic wiadomości, więc parser ramek działa na **bajtach**, a nie na słowach 32-bitowych. Nadawca powinien zawsze wysyłać całe ramki.
- Wybrano TCP zamiast UDP: przy łączu 100 Mbit i połączeniu bezpośrednim UDP daje minimalnie większy przepływ danych (mniejszy nagłówek), a TCP zapewnia niezawodność, kolejność i kontrolę przepływu bez dodatkowej logiki w FPGA.

## 3. Format ramki

Zapytania i odpowiedzi mają po 8 bajtów:

| Bajt | Pole | Rozmiar | Opis |
|------|------|---------|------|
| 0-1 | Magic number | 2 B | Stała `0xC7 0x3E`. Wartość spoza ASCII i bez wzorców typowych dla danych lub wypełnień (`0x00`, `0xFF`, `0xAA`, `0x55`, `0xA5`, `0x5A`). |
| 2 | Komenda | 1 B | Zobacz sekcję 4. |
| 3 | Adres | 1 B | Adres rejestru `0x00`-`0xFF`. |
| 4-7 | Dane | 4 B | Wartość rejestru (32 bity, big-endian). |

Przykład, zapis `0x00000003` do rejestru `0x30`:

```
C7 3E 01 30 00 00 00 03
```

## 4. Komendy

| Kod | Nazwa | Pole danych w zapytaniu |
|-----|-------|------------------------|
| `0x01` | WRITE | Wartość do zapisania. |
| `0x02` | READ | Ignorowane (wysyłane jako `0`). |
| `0x03`-`0x7F` | zarezerwowane | Na przyszłość, np. blokowy odczyt i zapis wielu słów. |

Bloki danych przebiegów nie są komendami zapytanie-odpowiedź. Są wysyłane po odpowiedzi na `CMD_READ_RECORD` (sekcja 9).

## 5. Odpowiedzi

Odpowiedź ma ten sam magic i adres co zapytanie, a ramka ma taki sam układ pól. Bajt komendy to komenda z zapytania z jedynką na bicie nr 7:

| Zapytanie | Komenda odpowiedzi | Dane odpowiedzi |
|-----------|--------------------|-----------------|
| WRITE (`0x01`) | `0x81` | Wartość faktycznie zapisana (po zamaskowaniu nieużywanych bitów). |
| READ (`0x02`) | `0x82` | Wartość rejestru. |
| dowolne, przy błędzie | `0xFF` | Kod błędu w najmłodszym bajcie. |

Kody błędów (proponowane):

| Kod | Nazwa | Znaczenie |
|-----|-------|-----------|
| `0x01` | ERR_UNKNOWN_CMD | Nierozpoznany bajt komendy. |
| `0x02` | ERR_BAD_ADDR | Adres nie istnieje (także adresy zarezerwowane). |
| `0x03` | ERR_READ_ONLY | Zapis do rejestru tylko do odczytu. |
| `0x04` | ERR_WRITE_ONLY | Odczyt rejestru tylko do zapisu. |
| `0x05` | ERR_BAD_VALUE | Wartość niepoprawna dla tego rejestru albo niespójna konfiguracja (sekcja 8). |

Ramce ze złym magic nie można bezpiecznie odpowiedzieć, bo nie wiadomo, czy nadawca zna protokół. Parser po cichu odrzuca bajty, aż znów zobaczy magic, i zwiększa licznik `CNT_BAD_MAGIC`.

Odpowiedzi nadchodzą w tej samej kolejności co zapytania, ponieważ TCP zachowuje kolejność i każde zapytanie ma dokładnie jedną odpowiedź.

### Przykłady

Zapis udany, `0x00000003` do `ACQ_MODE` (`0x30`):

```
zapytanie:  C7 3E 01 30 00 00 00 03
odpowiedź:  C7 3E 81 30 00 00 00 03
```

Odczyt `DEVICE_ID` (`0x00`), przykładowa wartość `0x0000AB01`:

```
zapytanie:  C7 3E 02 00 00 00 00 00
odpowiedź:  C7 3E 82 00 00 00 AB 01
```

Zapis do rejestru tylko do odczytu (`ERR_READ_ONLY`):

```
zapytanie:  C7 3E 01 00 DE AD BE EF
odpowiedź:  C7 3E FF 00 00 00 00 03
```

Odczyt adresu zarezerwowanego (`ERR_BAD_ADDR`):

```
zapytanie:  C7 3E 02 05 00 00 00 00
odpowiedź:  C7 3E FF 05 00 00 00 02
```

Przy zapisie do rejestru, który ma mniej znaczących bitów niż 32, odpowiedź zawiera wartość po zamaskowaniu. Na przykład zapis `0xFFFFFFFF` do `CH_OFFSET` (kod DAC ma 12 bitów) zwraca `0x00000FFF`.

## 6. Zachowanie parsera

- Maszyna stanów bajt po bajcie: szukanie magic, potem zbieranie komendy, adresu i 4 bajtów danych, potem wykonanie i wysłanie odpowiedzi.
- Gdy klient TCP się rozłączy, parser wraca do stanu bezczynności.
- Parser działa bezpośrednio na bajtowym interfejsie TCP rdzenia (`TCP0_Rx*` / `TCP0_Tx*`). Składanie słów 32-bitowych w `tcp_link.vhd` nie jest potrzebne dla ścieżki sterowania.
- Podczas nadawania bloku danych parser **nie przetwarza kolejnych ramek**. Zapytania czekają w buforze odbiorczym rdzenia (kontrola przepływu `TCP0_RxReady`), więc nie giną, a odpowiedzi nie wcinają się w środek bloku.
- **Planowane, poza pierwszą wersją:** limit czasu między bajtami. Niepełna ramka, która utknęła na dłużej niż limit, jest porzucana i liczona w `CNT_ABORTED`, dzięki czemu zawieszony klient nie blokuje parsera do rozłączenia.

## 7. Mapa rejestrów

Wszystkie rejestry mają 32 bity. Uprawnienia są wymuszane według zakresów adresów, więc dekoder sprawdza tylko górne bity adresu.

| Zakres | Strefa | Dostęp |
|--------|--------|--------|
| `0x00`-`0x0F` | Tożsamość i zgodność | Tylko odczyt, **zamrożone** |
| `0x10`-`0x1F` | Komendy | Tylko zapis (zapis uruchamia akcję) |
| `0x20`-`0x7F` | Konfiguracja | Odczyt i zapis |
| `0x80`-`0xEF` | Status | Tylko odczyt |
| `0xF0`-`0xFF` | Debug / eksperymentalne | Osobno dla każdego rejestru, można usunąć z wersji końcowej |

### 7.1 Tożsamość (`0x00`-`0x0F`, tylko odczyt)

Host czyta tę strefę jako pierwszą po połączeniu. Adresy w tej strefie nie mogą się przesunąć po publikacji.

| Adres | Nazwa | Opis |
|-------|-------|------|
| `0x00` | DEVICE_ID | Stała identyfikująca typ urządzenia. |
| `0x01` | PROTOCOL_VERSION | Wersja tego protokołu. Zgodność jest sprawdzana po niej, a nie po numerze builda. |
| `0x02` | GATEWARE_VERSION | Wersja projektu FPGA. |
| `0x03` | BUILD_TIMESTAMP | Data i godzina builda (albo skrót commita), pozwalająca ustalić, który bitstream jest wgrany. |
| `0x04` | CAPABILITIES | Pole bitowe: liczba kanałów, maksymalna długość rekordu, obsługiwane częstotliwości próbkowania. |
| `0x05`-`0x0F` | zarezerwowane | Odczyt zwraca błąd. |

### 7.2 Komendy (`0x10`-`0x1F`, tylko zapis)

Zapis uruchamia akcję. Zapisana wartość nie jest przechowywana. Odczyt zwraca `ERR_WRITE_ONLY`.

| Adres | Nazwa | Dane | Akcja |
|-------|-------|------|-------|
| `0x10` | CMD_COMMIT | ignorowane | Zastosuj całą oczekującą konfigurację atomowo między przechwyceniami. |
| `0x11` | CMD_ARM | ignorowane | Uzbrój akwizycję. |
| `0x12` | CMD_STOP | ignorowane | Zatrzymaj / rozbrój. |
| `0x13` | CMD_FORCE_TRIGGER | ignorowane | Wyzwól ręcznie. |
| `0x14` | CMD_CLEAR_FLAGS | maska bitowa | Skasuj lepkie flagi, których bity są ustawione w danych. |
| `0x15` | CMD_CLEAR_COUNTERS | ignorowane | Wyzeruj liczniki protokołu i błędów. |
| `0x16` | CMD_RESET_CONFIG | ignorowane | Przywróć konfigurację domyślną. |
| `0x17` | CMD_READ_RECORD | ignorowane | *(propozycja)* Wyślij ostatni kompletny rekord (sekcja 9). |
| `0x18`-`0x1F` | zarezerwowane | | |

### 7.3 Konfiguracja (`0x20`-`0x7F`, odczyt i zapis)

Odczyt rejestru konfiguracji zwraca wartość **zapisaną (oczekującą)**. Wartość faktycznie używana przez sprzęt jest dostępna w strefie statusu. Zobacz [Stosowanie konfiguracji](#stosowanie-konfiguracji-rejestry-cieniowe).

| Zakres | Blok |
|--------|------|
| `0x20`-`0x2F` | System i sprzęt |
| `0x30`-`0x3F` | Akwizycja |
| `0x40`-`0x4F` | Trigger |
| `0x50`-`0x5F` | Kanał 1 |
| `0x60`-`0x6F` | Kanał 2 |
| `0x70`-`0x7F` | zarezerwowane (przyszłe kanały lub funkcje) |

**System i sprzęt (`0x20`-`0x2F`)**

| Adres | Nazwa | Opis |
|-------|-------|------|
| `0x20` | SYS_CTRL | Ogólne bity sterujące (np. włączenie wzorca testowego ADC). |
| `0x21` | ADC_TEST_PATTERN | Wybór wzorca testowego do sprawdzania magistrali danych ADC. |
| `0x22` | ADC_DELAY | Wartość opóźnienia wejściowego do wyrównania danych ADC. |

**Akwizycja (`0x30`-`0x3F`)**

| Adres | Nazwa | Opis |
|-------|-------|------|
| `0x30` | ACQ_MODE | Auto, normal lub single. |
| `0x31` | ACQ_RECORD_LEN | Długość rekordu w próbkach **na kanał**. |
| `0x32` | ACQ_PRETRIGGER | Głębokość pre-triggera w próbkach na kanał. |
| `0x33` | ACQ_DECIMATION | Współczynnik decymacji częstotliwości próbkowania. |
| `0x34` | ACQ_CHANNEL_MASK | Maska kanałów zapisywanych i wysyłanych: bit 0 = kanał 1, bit 1 = kanał 2. Wartość `0` jest niepoprawna (`ERR_BAD_VALUE`). |

**Trigger (`0x40`-`0x4F`)**

| Adres | Nazwa | Opis |
|-------|-------|------|
| `0x40` | TRIG_SOURCE | Kanał źródłowy. Musi być włączony w `ACQ_CHANNEL_MASK`. |
| `0x41` | TRIG_EDGE | Zbocze narastające, opadające lub oba. |
| `0x42` | TRIG_LEVEL | Poziom w jednostkach ADC. |
| `0x43` | TRIG_HYSTERESIS | Histereza w jednostkach ADC. |
| `0x44` | TRIG_HOLDOFF | Holdoff w próbkach. |

**Bloki kanałów (`0x50` dla kanału 1, `0x60` dla kanału 2)**

Oba kanały mają identyczny układ ze stałym krokiem `0x10`. Adres rejestru wynosi `0x50 + (kanał - 1) * 0x10 + offset`.

| Offset | Nazwa | Opis |
|--------|-------|------|
| `+0x0` | CH_GAIN | Słowo wzmocnienia AD8370 i bit zakresu. |
| `+0x1` | CH_OFFSET | Kod DAC MCP4822 (12 bitów). |
| `+0x2` | CH_TRIM_OFFSET | Cyfrowy offset dokładny stosowany do próbek. |
| `+0x3` | CH_TRIM_GAIN | Cyfrowe wzmocnienie dokładne stosowane do próbek. |
| `+0x4`-`+0xF` | zarezerwowane | |

### 7.4 Status (`0x80`-`0xEF`, tylko odczyt)

| Zakres | Blok |
|--------|------|
| `0x80`-`0x8F` | Stan układu |
| `0x90`-`0x9F` | Liczniki protokołu |
| `0xA0`-`0xAF` | Status akwizycji |
| `0xB0`-`0xBF` | Status kanału 1 |
| `0xC0`-`0xCF` | Status kanału 2 |
| `0xD0`-`0xEF` | zarezerwowane |

**Stan układu (`0x80`-`0x8F`)**

| Adres | Nazwa | Opis |
|-------|-------|------|
| `0x80` | SYS_STATUS | Bity chwilowe: zegary zablokowane, klient TCP połączony, zegar ADC obecny. |
| `0x81` | SYS_FLAGS | **Lepkie** bity zdarzeń (np. przepełnienie bufora). Kasowane przez `CMD_CLEAR_FLAGS`. |
| `0x82` | UPTIME | Sekundy od resetu. Spadek oznacza, że urządzenie się zrestartowało. |

**Liczniki protokołu (`0x90`-`0x9F`)**

| Adres | Nazwa | Opis |
|-------|-------|------|
| `0x90` | CNT_FRAMES_OK | Poprawnie przetworzone ramki. |
| `0x91` | CNT_BAD_MAGIC | Bajty lub ramki odrzucone przez zły magic. |
| `0x92` | CNT_UNKNOWN_CMD | Odebrane nieznane komendy. |
| `0x93` | CNT_BAD_ADDR | Dostępy do nieistniejących adresów. |
| `0x94` | CNT_ABORTED | Ramki porzucone przez limit czasu między bajtami (po jego wprowadzeniu). |

**Status akwizycji (`0xA0`-`0xAF`)**

| Adres | Nazwa | Opis |
|-------|-------|------|
| `0xA0` | ACQ_STATE | Bezczynny, uzbrojony, wyzwolony, gotowy. |
| `0xA1` | ACQ_WRITE_PTR | Bieżący wskaźnik zapisu. |
| `0xA2` | ACQ_TRIGGER_PTR | Pozycja próbki, w której nastąpiło wyzwolenie. |
| `0xA3` | ACQ_SAMPLES | Liczba zebranych próbek na kanał. |
| `0xA4` | ACQ_RECORD_ID | Numer ostatniego kompletnego rekordu (zwiększany po każdym przechwyceniu). |

**Status kanału (`0xB0` dla kanału 1, `0xC0` dla kanału 2)**

| Offset | Nazwa | Opis |
|--------|-------|------|
| `+0x0` | CH_APPLIED_GAIN | Słowo wzmocnienia faktycznie używane. |
| `+0x1` | CH_APPLIED_OFFSET | Kod DAC faktycznie używany. |
| `+0x2` | CH_FLAGS | Lepka flaga przesterowania ADC, chwilowy bit zajętości SPI. |

### 7.5 Debug (`0xF0`-`0xFF`)

Uprawnienia są tu określone osobno dla każdego rejestru. Strefa jest przeznaczona do usunięcia lub ukrycia w wersjach końcowych.

| Adres | Nazwa | Dostęp | Opis |
|-------|-------|--------|------|
| `0xF0` | DBG_SCRATCH0 | R/W | Przechowuje dowolną wartość. Pierwszy test protokołu od końca do końca. |
| `0xF1` | DBG_SCRATCH1 | R/W | Drugi rejestr roboczy. |
| `0xF2` | DBG_LED | R/W | Steruje diodami LED na płytce, dając widoczny efekt. |
| `0xF3` | DBG_CONST | R | Stała `0xDEADBEEF`, test odczytu bez żadnego stanu. |

## 8. Semantyka

### Lepkie flagi

Lepka flaga ustawia się, gdy zdarzy się zdarzenie (nawet trwające jeden takt zegara) i pozostaje ustawiona, dopóki nie zostanie skasowana. Zwykła flaga pokazuje tylko stan chwilowy, więc krótki błąd mógłby zniknąć, zanim zostanie odczytany. Lepkie flagi znajdują się w `SYS_FLAGS` i `CH_FLAGS` i są kasowane przez `CMD_CLEAR_FLAGS`, dzięki czemu strefa statusu nie ma wyjątków od zasady "tylko odczyt".

### Stosowanie konfiguracji (rejestry cieniowe)

Każdy rejestr konfiguracji ma dwie kopie: **oczekującą** (shadow) i **aktywną**. Zapis trafia wyłącznie do kopii oczekującej, a sprzęt pracuje na aktywnej. Dopiero `CMD_COMMIT` kopiuje wszystkie wartości oczekujące do aktywnych jednocześnie, w bezpiecznym momencie między przechwyceniami. Pozwala to uniknąć stanów częściowo zaktualizowanych, np. nowego wzmocnienia ze starym kodem offsetu, które objawiałyby się skokiem przebiegu. Mechanizm odpowiada wejściowym rejestrom i wejściu LDAC przetwornika MCP4822.

Odczyt rejestru konfiguracji zwraca wartość oczekującą. Strefa statusu zawiera lustra wartości aktywnych (`CH_APPLIED_*`), więc porównanie wartości zapisanej z zastosowaną potwierdza, że ustawienie weszło w życie.

### Walidacja konfiguracji *(propozycja)*

Są dwa poziomy sprawdzania:

1. **Wartość pojedyncza.** Wartość niepoprawna sama w sobie (np. `ACQ_CHANNEL_MASK = 0`, wartość poza zakresem rejestru) jest odrzucana przy zapisie odpowiedzią `ERR_BAD_VALUE`, a rejestr zachowuje poprzednią wartość.
2. **Zależności między rejestrami.** Reguły dotyczące kilku rejestrów, np. "źródło wyzwalania musi należeć do kanałów włączonych w `ACQ_CHANNEL_MASK`", są sprawdzane dopiero przy `CMD_COMMIT`, bo wynik nie powinien zależeć od kolejności zapisów. Przy naruszeniu `CMD_COMMIT` zwraca `ERR_BAD_VALUE` i **nic nie jest stosowane**: konfiguracja aktywna pozostaje bez zmian.

## 9. Przesyłanie rekordów

### Przebieg

1. Host konfiguruje akwizycję i zatwierdza ją przez `CMD_COMMIT`.
2. Host uzbraja akwizycję (`CMD_ARM`).
3. Host odpytuje `ACQ_STATE`, aż rekord będzie gotowy.
4. Host wysyła `CMD_READ_RECORD` *(propozycja)*. FPGA odpowiada zwykłą 8-bajtową ramką (`0x81` przy powodzeniu, `0xFF` z `ERR_BAD_VALUE`, gdy nie ma gotowego rekordu), a po niej **bezpośrednio** wysyła blok danych.

Ponieważ blok następuje zawsze po potwierdzeniu `CMD_READ_RECORD`, host wie, kiedy czytać nagłówek, i nie musi odróżniać bloku od odpowiedzi.

### Blok danych

Blok składa się z nagłówka o stałej długości 64 bajtów i następującego po nim ciągu próbek.

**Nagłówek rekordu *(propozycja)***

| Bajt | Pole | Rozmiar | Opis |
|------|------|---------|------|
| 0-1 | Magic | 2 B | `0xC7 0x3E`. |
| 2 | Typ | 1 B | `0xD0` (blok danych). |
| 3 | Flagi | 1 B | Bit 0: w trakcie rekordu wystąpiło przesterowanie ADC. Pozostałe zarezerwowane. |
| 4-7 | PAYLOAD_LEN | 4 B | Długość części z próbkami w bajtach. |
| 8-11 | RECORD_ID | 4 B | Numer rekordu (jak `ACQ_RECORD_ID`). |
| 12 | CHANNEL_MASK | 1 B | Maska kanałów obecnych w rekordzie. |
| 13 | SAMPLE_BITS | 1 B | Liczba bitów na próbkę (obecnie 8). |
| 14-15 | zarezerwowane | 2 B | Zera. |
| 16-19 | SAMPLES_PER_CH | 4 B | Liczba próbek na kanał. |
| 20-23 | TRIGGER_POS | 4 B | Indeks próbki, w której nastąpiło wyzwolenie (licząc od początku rekordu, na kanał). |
| 24-27 | DECIMATION | 4 B | Współczynnik decymacji użyty przy zapisie rekordu. |
| 28-31 | zarezerwowane | 4 B | Zera. |
| 32-35 | CH1_GAIN | 4 B | Wartość `CH_APPLIED_GAIN` kanału 1 w chwili przechwytywania. Zero, gdy kanał wyłączony. |
| 36-39 | CH1_OFFSET | 4 B | Wartość `CH_APPLIED_OFFSET` kanału 1. |
| 40-43 | CH1_INPUT | 4 B | Wartość `CH_APPLIED_INPUT` kanału 1. |
| 44-47 | zarezerwowane | 4 B | Zera. |
| 48-51 | CH2_GAIN | 4 B | To samo dla kanału 2. |
| 52-55 | CH2_OFFSET | 4 B | |
| 56-59 | CH2_INPUT | 4 B | |
| 60-63 | zarezerwowane | 4 B | Zera. |

Nagłówek zawiera migawkę ustawień z chwili przechwytywania, więc rekord jest samoopisujący się i późniejsze zmiany konfiguracji nie wpływają na jego interpretację.

**Próbki**

Po nagłówku następuje `PAYLOAD_LEN` bajtów próbek, bez żadnych nagłówków ani znaczników w środku. Układ zależy od `CHANNEL_MASK`:

| Maska | Układ próbek |
|-------|--------------|
| `01` (tylko kanał 1) | `ch1[0] ch1[1] ch1[2] ...` |
| `10` (tylko kanał 2) | `ch2[0] ch2[1] ch2[2] ...` |
| `11` (oba kanały) | **przeplot próbka po próbce:** `ch1[0] ch2[0] ch1[1] ch2[1] ...` |

Zależność długości: `PAYLOAD_LEN = SAMPLES_PER_CH × (liczba włączonych kanałów) × (SAMPLE_BITS / 8)`.

Próbka jest surowym kodem z przetwornika, bez konwersji po stronie FPGA.

### Zasady nadawania

- Blok jest **niepodzielny**: po jego rozpoczęciu FPGA nie wysyła niczego innego, dopóki nie wyśle ostatniej próbki.
- W tym czasie zapytania hosta czekają w buforze odbiorczym (sekcja 6). Odpowiedzi na nie wracają po zakończeniu bloku, w kolejności zapytań.
- Tempo nadawania wyznacza kontrola przepływu TCP (`TCP0_TxReady`). Nadajnik FPGA czeka, gdy rdzeń nie może przyjąć kolejnego bajtu.

### Przepustowość

Przy łączu 100 Mbit teoretyczny przepływ danych użytkowych przy pełnych segmentach TCP wynosi około 11,8 MB/s. Wartość rzeczywista zależy od implementacji rdzenia (rozmiar segmentów, bufor nadawczy) i wymaga pomiaru, np. przez wysłanie strumienia z licznikiem i sprawdzenie ciągłości po stronie hosta.

## 10. Uwagi implementacyjne

- **Parser bajtowy** jako maszyna o 8 stanach: dwa bajty magic, komenda, adres, cztery bajty danych.
- **Dekoder adresów** oparty na górnych bitach adresu, który wyznacza uprawnienia całej strefy, z wyjątkiem strefy debug.
- **Nadajnik bloków** jako osobna maszyna stanów: nagłówek (64 bajty, z rejestrów statusu i migawki), potem odczyt pamięci próbek i wysyłanie bajt po bajcie z czekaniem na `TCP0_TxReady`.
- **Przeplot** w FPGA wynika z samego sposobu zapisu: przetwornik dostarcza próbki obu kanałów w tym samym takcie, więc nadajnik wysyła je kolejno bez dodatkowej logiki.
- **Jedno źródło prawdy** dla mapy rejestrów, np. plik YAML lub JSON i skrypt generujący pakiet VHDL oraz stałe po stronie hosta.

## 11. Podjęte decyzje

| Temat | Decyzja |
|-------|---------|
| Transport | TCP dla sterowania i danych, jedno połączenie. UDP odrzucony. |
| Dane przebiegów | Surowe: jeden nagłówek na rekord, potem ciągły strumień próbek. |
| Wybór kanałów | Rejestr `ACQ_CHANNEL_MASK`. Przy jednym włączonym kanale rekord zawiera tylko jego próbki. |
| Układ próbek przy dwóch kanałach | Przeplot próbka po próbce. |
| Trigger | Źródło wyzwalania musi należeć do włączonych kanałów. |
| Rejestry cieniowe | Zapisy do rejestrów oczekujących, zastosowanie przez `CMD_COMMIT`. |
| Kodowanie odpowiedzi | Bit 7 ustawiony w bajcie komendy dla odpowiedzi poprawnych i `0xFF` dla błędów. |
| Magic | `0xC7 0x3E`. Magic służy synchronizacji ramek. Uszkodzenia transmisji wykrywają sumy kontrolne Ethernetu i TCP. |
| Limit czasu między bajtami | Odłożony do późniejszej implementacji. |
| Układy bitowe rejestrów | Definiowane przy implementacji kolejnych funkcji. |

<!-- ## 12. Kwestie nierozstrzygnięte -->
<!---->
<!-- 1. **Pobieranie rekordów:** na żądanie przez `CMD_READ_RECORD` (opisane w sekcji 9) czy automatycznie po zakończeniu przechwytywania (tryb push, bez odpytywania `ACQ_STATE`). -->
<!-- 2. **Format próbki:** czy wysyłać surowy kod z przetwornika, czy konwertować w FPGA do postaci ze znakiem (zależnie od formatu danych wyjściowych AD9288, do sprawdzenia w nocie katalogowej). -->
<!-- 3. **Pamięć próbek:** czy kanał wyłączony w `ACQ_CHANNEL_MASK` nie zajmuje pamięci (rekord może być wtedy dwa razy dłuższy przy jednym kanale), oraz maksymalna wartość `ACQ_RECORD_LEN` zależna od maski. -->
<!-- 4. **Odpowiedź błędu:** czy pole danych powinno zawierać dodatkowe informacje, np. oryginalną komendę i adres rejestru, którego dotyczy błąd (szczególnie przy `CMD_COMMIT` odrzuconym z powodu niespójnej konfiguracji). Ramka zachowuje wtedy ten sam rozmiar. -->
<!-- 5. **Zawartość nagłówka rekordu:** ostateczny zestaw pól (np. znacznik czasu lub numer wersji nagłówka). -->
