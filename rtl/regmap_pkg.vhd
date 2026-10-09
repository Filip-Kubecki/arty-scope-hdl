library ieee;
use ieee.std_logic_1164.all;

package regmap_pkg is

    subtype byte_t is std_logic_vector(7 downto 0);
    subtype word_t is std_logic_vector(31 downto 0);

    -- -------------------------------------------------------------------------
    -- Magic - oba bajty spoza ASCII (>= 0x80)
    -- -------------------------------------------------------------------------
    constant MAGIC_0 : byte_t := x"C7";
    constant MAGIC_1 : byte_t := x"E2";

    -- -------------------------------------------------------------------------
    -- Komendy zapytań
    -- -------------------------------------------------------------------------
    constant COMMAND_WRITE          : byte_t := x"01";
    constant COMMAND_READ           : byte_t := x"02";

    -- Odpowiedzi - bit 7 ustawiony na High w komendzie zapytania
    constant COMMAND_RESPONSE_BIT   : natural := 7;
    constant RESPONSE_WRITE         : byte_t := x"81";
    constant RESPONSE_READ          : byte_t := x"82";
    constant RESPONSE_ERROR         : byte_t := x"FF";  -- kod błędu w najmłodszym bajcie danych

    -- -------------------------------------------------------------------------
    -- Kody błędów
    -- -------------------------------------------------------------------------
    constant ERROR_UNKNOWN_COMMAND  : byte_t := x"01";
    constant ERROR_BAD_ADDRESS      : byte_t := x"02";  -- także adresy zarezerwowane
    constant ERROR_READ_ONLY        : byte_t := x"03";
    constant ERROR_WRITE_ONLY       : byte_t := x"04";
    constant ERROR_BAD_VALUE        : byte_t := x"05";  -- też COMMIT z niespójną konfiguracją; wtedy nic nie zostaje zastosowane
    constant ERROR_NOT_READY        : byte_t := x"06";  -- brak gotowego rekordu przy ADDR_COMMAND_READ_RECORD

    -- -------------------------------------------------------------------------
    -- Blok danych rekordu
    -- -------------------------------------------------------------------------
    constant RECORD_TYPE_DATA       : byte_t  := x"D0";
    constant RECORD_HEADER_LENGTH   : natural := 64;   -- bajty
    constant RECORD_SAMPLE_BITS     : natural := 8;    -- bity na próbkę (obecnie); zmiana wpływa na PAYLOAD_LEN

    -- -------------------------------------------------------------------------
    -- Typy dostępu
    -- -------------------------------------------------------------------------
    type access_t is (ACCESS_NONE, ACCESS_READ_ONLY, ACCESS_WRITE_ONLY, ACCESS_READ_WRITE);

    -- -------------------------------------------------------------------------
    -- Zakresy stref - dekoder sprawdza górne bity adresu
    -- -------------------------------------------------------------------------
    constant ZONE_ID_LO             : byte_t := x"00";  -- 0x00-0x0F tożsamość, RO
    constant ZONE_ID_HI             : byte_t := x"0F";
    constant ZONE_COMMAND_LO        : byte_t := x"10";  -- 0x10-0x1F komendy, WO (odczyt daje ERROR_WRITE_ONLY)
    constant ZONE_COMMAND_HI        : byte_t := x"1F";
    constant ZONE_CONFIG_LO         : byte_t := x"20";  -- 0x20-0x7F konfiguracja, RW (zapis do oczekującej kopii)
    constant ZONE_CONFIG_HI         : byte_t := x"7F";
    constant ZONE_STATUS_LO         : byte_t := x"80";  -- 0x80-0xEF status, RO
    constant ZONE_STATUS_HI         : byte_t := x"EF";
    constant ZONE_DEBUG_LO          : byte_t := x"F0";  -- 0xF0-0xFF debug, uprawnienia per rejestr; do usunięcia w wersji końcowej
    constant ZONE_DEBUG_HI          : byte_t := x"FF";

    -- -------------------------------------------------------------------------
    -- Tożsamość urządzenia (Read Only)
    -- -------------------------------------------------------------------------
    constant ADDR_DEVICE_ID         : byte_t := x"00";  -- stała identyfikująca typ urządzenia
    constant ADDR_PROTOCOL_VERSION  : byte_t := x"01";  -- zgodność sprawdzana po wersji protokołu
    constant ADDR_GATEWARE_VERSION  : byte_t := x"02";  -- wersja projektu FPGA
    constant ADDR_BUILD_TIMESTAMP   : byte_t := x"03";  -- data builda albo skrót commita
    constant ADDR_CAPABILITIES      : byte_t := x"04";  -- pole bitowe: liczba kanałów, max długość rekordu, częstotliwości

    -- Wartości tożsamości            TODO: do uzupełnienia w ostatecznym pierwszym buildzie w release
    constant VAL_DEVICE_ID          : word_t := x"0000AB01";  -- przykładowa
    constant VAL_PROTOCOL_VERSION   : word_t := x"00000001";

    -- -------------------------------------------------------------------------
    -- Komendy (Write Only, zapis uruchamia akcję, wartość w danych ignorowana
    -- chyba że zaznaczono inaczej)
    -- -------------------------------------------------------------------------
    constant ADDR_COMMAND_COMMIT         : byte_t := x"10";  -- zapisuje wszystkie wartości oczekujące do aktywnych naraz, między przechwyceniami; przy niespójności ERROR_BAD_VALUE i nic nie zmienia
    constant ADDR_COMMAND_ARM            : byte_t := x"11";  -- uzbraja akwizycję, czeka na trigger
    constant ADDR_COMMAND_STOP           : byte_t := x"12";  -- zatrzymuje akwizycję, nie zmienia konfiguracji
    constant ADDR_COMMAND_FORCE_TRIGGER  : byte_t := x"13";  -- wyzwala od razu, bez czekania na warunek zbocza/poziomu
    constant ADDR_COMMAND_CLEAR_FLAGS    : byte_t := x"14";  -- DANE = MASKA: kasuje lepkie flagi, których bit jest 1 (dane NIE są ignorowane)
    constant ADDR_COMMAND_CLEAR_COUNTERS : byte_t := x"15";  -- zeruje liczniki protokołu (0x90-0x93), UPTIME bez zmian
    constant ADDR_COMMAND_RESET_CONFIG   : byte_t := x"16";  -- ustawia wartości domyślne w rejestrach OCZEKUJĄCYCH; aktywne zmieni dopiero COMMIT
    constant ADDR_COMMAND_READ_RECORD    : byte_t := x"17";  -- model pull: wysyła ostatni kompletny rekord po odpowiedzi; bez gotowego rekordu ERROR_NOT_READY (protocol.md, sekcja 9)

    -- -------------------------------------------------------------------------
    -- Konfiguracja (Read-Write, odczyt zwraca wartość oczekującą)
    -- -------------------------------------------------------------------------

    -- System i sprzęt
    constant ADDR_SYSTEM_CONTROL         : byte_t := x"20";  -- bity ogólne
    constant ADDR_ADC_TEST_PATTERN       : byte_t := x"21";  -- wzorzec zamiast próbek z ADC, do testu magistrali danych
    constant ADDR_ADC_DELAY              : byte_t := x"22";  -- opóźnienie wejścia ADC, wyrównuje dane do zegara

    -- Akwizycja
    constant ADDR_ACQUISITION_MODE           : byte_t := x"30";  -- auto / normal / single
    constant ADDR_ACQUISITION_RECORD_LENGTH  : byte_t := x"31";  -- w próbkach NA KANAŁ, nie łącznie
    constant ADDR_ACQUISITION_PRETRIGGER     : byte_t := x"32";  -- próbki przed wyzwoleniem, na kanał
    constant ADDR_ACQUISITION_DECIMATION     : byte_t := x"33";  -- zmniejszenie częstotliwości próbkowania
    constant ADDR_ACQUISITION_CHANNEL_MASK   : byte_t := x"34";  -- bit 0 = kanał 1, bit 1 = kanał 2; wartość 0 niepoprawna

    -- Trigger
    constant ADDR_TRIGGER_SOURCE         : byte_t := x"40";  -- kanał źródłowy; musi być włączony w CHANNEL_MASK, sprawdzane przy COMMIT, nie przy zapisie
    constant ADDR_TRIGGER_EDGE           : byte_t := x"41";  -- zbocze narastające, opadające lub oba
    constant ADDR_TRIGGER_LEVEL          : byte_t := x"42";  -- poziom w jednostkach ADC
    constant ADDR_TRIGGER_HYSTERESIS     : byte_t := x"43";  -- pasmo wokół poziomu wyzwalania. Zapobiega ciągłym wyzwoleniom przy sygnale/szumie blisko granicy wyzwalania
    constant ADDR_TRIGGER_HOLDOFF        : byte_t := x"44";  -- martwy czas po wyzwoleniu, w próbkach; w tym czasie trigger ignorowany

    -- Kanał 1
    constant CHANNEL1_CONFIG              : byte_t := x"50";
    constant ADDR_CHANNEL1_GAIN           : byte_t := x"50";  -- słowo wzmocnienia AD8370 + bit zakresu
    constant ADDR_CHANNEL1_OFFSET         : byte_t := x"51";  -- kod DAC MCP4822

    -- Kanał 2
    constant CHANNEL2_CONFIG              : byte_t := x"60";
    constant ADDR_CHANNEL2_GAIN           : byte_t := x"60";
    constant ADDR_CHANNEL2_OFFSET         : byte_t := x"61";

    -- -------------------------------------------------------------------------
    -- Status (Read Only)
    -- -------------------------------------------------------------------------

    -- Stan układu
    constant ADDR_SYSTEM_STATUS          : byte_t := x"80";  -- bity chwilowe: zegary, połączenie TCP, zegar ADC
    constant ADDR_SYSTEM_FLAGS           : byte_t := x"81";  -- LEPKIE: ustawiają się na zdarzenie, kasowane przez COMMAND_CLEAR_FLAGS z maską
    constant ADDR_UPTIME                 : byte_t := x"82";  -- sekundy od resetu; spadek oznacza restart urządzenia

    -- Liczniki protokołu
    constant ADDR_COUNTER_FRAMES_OK      : byte_t := x"90";  -- poprawnie przetworzone ramki
    constant ADDR_COUNTER_BAD_MAGIC      : byte_t := x"91";  -- bajty lub ramki odrzucone przez zły magic
    constant ADDR_COUNTER_UNKNOWN_COMMAND: byte_t := x"92";
    constant ADDR_COUNTER_BAD_ADDRESS    : byte_t := x"93";

    -- Status akwizycji
    constant ADDR_ACQUISITION_STATE          : byte_t := x"A0";  -- bezczynny / uzbrojony / wyzwolony / gotowy
    constant ADDR_ACQUISITION_WRITE_POINTER  : byte_t := x"A1";  -- bieżący wskaźnik zapisu
    constant ADDR_ACQUISITION_TRIGGER_POINTER: byte_t := x"A2";  -- indeks próbki, w której nastąpiło wyzwolenie
    constant ADDR_ACQUISITION_SAMPLES        : byte_t := x"A3";  -- zebrane próbki na kanał
    constant ADDR_ACQUISITION_RECORD_ID      : byte_t := x"A4";  -- rośnie po każdym kompletnym rekordzie

    -- Status kanału 1
    constant ADDR_CHANNEL1_APPLIED_GAIN   : byte_t := x"B0";  -- lustro wartości AKTYWNEJ; porównanie z oczekującą potwierdza COMMIT
    constant ADDR_CHANNEL1_APPLIED_OFFSET : byte_t := x"B1";  -- lustro wartości AKTYWNEJ
    constant ADDR_CHANNEL1_FLAGS          : byte_t := x"B2";  -- bit przesterowania LEPKI; bit zajętości SPI CHWILOWY

    -- Status kanału 2
    constant ADDR_CHANNEL2_APPLIED_GAIN   : byte_t := x"C0";
    constant ADDR_CHANNEL2_APPLIED_OFFSET : byte_t := x"C1";
    constant ADDR_CHANNEL2_FLAGS          : byte_t := x"C2";

    -- -------------------------------------------------------------------------
    -- DEBUG (uprawnienia per rejestr)
    -- -------------------------------------------------------------------------
    constant ADDR_DEBUG_SCRATCH0    : byte_t := x"F0";       -- R/W, pierwszy test protokołu end-to-end
    constant ADDR_DEBUG_SCRATCH1    : byte_t := x"F1";       -- R/W, rejestr roboczy
    constant ADDR_DEBUG_LED         : byte_t := x"F2";       -- R/W, bity sterują diodami na płytce
    constant ADDR_DEBUG_CONST       : byte_t := x"F3";       -- R, zawsze VAL_DEBUG_CONST (test odczytu)

    constant VAL_DEBUG_CONST        : word_t := x"DEADBEEF"; -- R

end package regmap_pkg;
