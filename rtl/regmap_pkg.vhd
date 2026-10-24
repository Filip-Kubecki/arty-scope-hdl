-- GENEROWANE z regmap.yaml. Nie edytuj ręcznie.
library ieee;
use ieee.std_logic_1164.all;

package regmap_pkg is

    subtype byte_t is std_logic_vector(7 downto 0);
    subtype word_t is std_logic_vector(31 downto 0);

    -- Stałe protokołu
    constant MAGIC_0 : byte_t := x"C7";  -- Magic, bajt 0
    constant MAGIC_1 : byte_t := x"E2";  -- Magic, bajt 1
    constant COMMAND_WRITE : byte_t := x"01";  -- Zapis
    constant COMMAND_READ : byte_t := x"02";  -- Odczyt
    constant COMMAND_RESPONSE_BIT : natural := 7;  -- Bit odpowiedzi
    constant RESPONSE_WRITE : byte_t := x"81";  -- Odpowiedź na zapis
    constant RESPONSE_READ : byte_t := x"82";  -- Odpowiedź na odczyt
    constant RESPONSE_ERROR : byte_t := x"FF";  -- Odpowiedź błędu, kod w najmłodszym bajcie danych
    constant RECORD_TYPE_DATA : byte_t := x"D0";  -- Typ bloku danych
    constant RECORD_HEADER_LENGTH : natural := 64;  -- Długość nagłówka w bajtach
    constant RECORD_SAMPLE_BITS : natural := 8;  -- Bity na próbkę (obecnie)
    constant RECORD_MAX_SAMPLES : natural := 65536;  -- Maksymalna liczba próbek na kanał w rekordzie
    constant ZONE_ID_LO : byte_t := x"00";  -- Tożsamość, początek
    constant ZONE_ID_HI : byte_t := x"0F";  -- Tożsamość, koniec
    constant ZONE_COMMAND_LO : byte_t := x"10";  -- Komendy, początek
    constant ZONE_COMMAND_HI : byte_t := x"1F";  -- Komendy, koniec
    constant ZONE_CONFIG_LO : byte_t := x"20";  -- Konfiguracja, początek
    constant ZONE_CONFIG_HI : byte_t := x"7F";  -- Konfiguracja, koniec
    constant ZONE_STATUS_LO : byte_t := x"80";  -- Status, początek
    constant ZONE_STATUS_HI : byte_t := x"EF";  -- Status, koniec
    constant ZONE_DEBUG_LO : byte_t := x"F0";  -- Debug, początek
    constant ZONE_DEBUG_HI : byte_t := x"FF";  -- Debug, koniec
    constant CHANNEL1_CONFIG : byte_t := x"50";  -- Baza konfiguracji kanału 1
    constant CHANNEL2_CONFIG : byte_t := x"60";  -- Baza konfiguracji kanału 2

    -- Kody błędów
    constant ERROR_UNKNOWN_COMMAND : byte_t := x"01";  -- Nierozpoznany bajt komendy
    constant ERROR_BAD_ADDRESS : byte_t := x"02";  -- Adres nieistniejący, zarezerwowany lub niewspierany
    constant ERROR_READ_ONLY : byte_t := x"03";  -- Zapis do rejestru tylko do odczytu
    constant ERROR_WRITE_ONLY : byte_t := x"04";  -- Odczyt rejestru tylko do zapisu
    constant ERROR_BAD_VALUE : byte_t := x"05";  -- Wartość niepoprawna albo niespójna konfiguracja przy COMMIT
    constant ERROR_NOT_READY : byte_t := x"06";  -- Brak gotowego rekordu przy READ_RECORD

    -- Adresy rejestrów i komend (wszystkie statusy)
    constant ADDR_DEVICE_ID : byte_t := x"00";  -- implemented: Identyfikator urządzenia (wartość przykładowa, do potwierdzenia)
    constant VAL_DEVICE_ID : word_t := x"0000AB01";
    constant ADDR_PROTOCOL_VERSION : byte_t := x"01";  -- implemented: Wersja protokołu
    constant VAL_PROTOCOL_VERSION : word_t := x"00000002";
    constant ADDR_GATEWARE_VERSION : byte_t := x"02";  -- planned: Wersja projektu FPGA
    constant ADDR_BUILD_TIMESTAMP : byte_t := x"03";  -- planned: Data builda albo skrót commita
    constant ADDR_CAPABILITIES : byte_t := x"04";  -- planned: Liczba kanałów, maks. długość rekordu, częstotliwości
    constant ADDR_COMMAND_COMMIT : byte_t := x"10";  -- implemented: Zatwierdzenie konfiguracji oczekującej
    constant ADDR_COMMAND_ARM : byte_t := x"11";  -- implemented: Uzbrojenie akwizycji
    constant ADDR_COMMAND_STOP : byte_t := x"12";  -- implemented: Zatrzymanie akwizycji, powrót do IDLE
    constant ADDR_COMMAND_FORCE_TRIGGER : byte_t := x"13";  -- implemented: Ręczne wyzwolenie z ARMED
    constant ADDR_COMMAND_CLEAR_FLAGS : byte_t := x"14";  -- accepted: Kasowanie flag, dane = maska (dziś bez efektu)
    constant ADDR_COMMAND_CLEAR_COUNTERS : byte_t := x"15";  -- implemented: Zerowanie liczników
    constant ADDR_COMMAND_RESET_CONFIG : byte_t := x"16";  -- implemented: Wartości domyślne w rejestrach oczekujących (dziś bez efektu)
    constant ADDR_COMMAND_READ_RECORD : byte_t := x"17";  -- implemented: Wysłanie ostatniego kompletnego rekordu
    constant ADDR_SYSTEM_CONTROL : byte_t := x"20";  -- planned: Bity ogólne
    constant ADDR_ADC_TEST_PATTERN : byte_t := x"21";  -- planned: Wzorzec testowy zamiast próbek z ADC
    constant ADDR_ADC_DELAY : byte_t := x"22";  -- planned: Opóźnienie wejścia ADC
    constant ADDR_ACQUISITION_MODE : byte_t := x"30";  -- planned: Auto, normal lub single
    constant ADDR_ACQUISITION_RECORD_LENGTH : byte_t := x"31";  -- implemented: Długość rekordu. 1–131072 przy masce 01 lub 02, 1–65536 przy 03, aktywna po COMMIT
    constant ADDR_ACQUISITION_PRETRIGGER : byte_t := x"32";  -- implemented: Próbki przed wyzwoleniem, na kanał
    constant ADDR_ACQUISITION_DECIMATION : byte_t := x"33";  -- implemented: Co N-ta próbka trafia do rekordu
    constant ADDR_ACQUISITION_CHANNEL_MASK : byte_t := x"34";  -- implemented: Maska kanałów: bit 0 = kanał 1, bit 1 = kanał 2, 0 niepoprawne
    constant ADDR_TRIGGER_SOURCE : byte_t := x"40";  -- implemented: Kanał źródłowy wyzwalania
    constant ADDR_TRIGGER_EDGE : byte_t := x"41";  -- implemented: Zbocze: narastające, opadające lub oba
    constant ADDR_TRIGGER_LEVEL : byte_t := x"42";  -- implemented: Poziom w jednostkach ADC
    constant ADDR_TRIGGER_HYSTERESIS : byte_t := x"43";  -- implemented: Pasmo wokół poziomu wyzwalania
    constant ADDR_TRIGGER_HOLDOFF : byte_t := x"44";  -- planned: Martwy czas po wyzwoleniu, w próbkach
    constant ADDR_CHANNEL1_GAIN : byte_t := x"50";  -- planned: Słowo wzmocnienia AD8370 i bit zakresu, kanał 1
    constant ADDR_CHANNEL1_OFFSET : byte_t := x"51";  -- planned: Kod DAC MCP4822, kanał 1
    constant ADDR_CHANNEL2_GAIN : byte_t := x"60";  -- planned: Słowo wzmocnienia AD8370 i bit zakresu, kanał 2
    constant ADDR_CHANNEL2_OFFSET : byte_t := x"61";  -- planned: Kod DAC MCP4822, kanał 2
    constant ADDR_SYSTEM_STATUS : byte_t := x"80";  -- planned: Bity chwilowe: zegary, połączenie TCP, zegar ADC
    constant ADDR_SYSTEM_FLAGS : byte_t := x"81";  -- planned: Lepkie flagi zdarzeń
    constant ADDR_UPTIME : byte_t := x"82";  -- planned: Sekundy od resetu
    constant ADDR_COUNTER_FRAMES_OK : byte_t := x"90";  -- implemented: Poprawnie przetworzone ramki
    constant ADDR_COUNTER_BAD_MAGIC : byte_t := x"91";  -- implemented: Bajty lub ramki odrzucone przez zły magic
    constant ADDR_COUNTER_UNKNOWN_COMMAND : byte_t := x"92";  -- implemented: Nieznane komendy
    constant ADDR_COUNTER_BAD_ADDRESS : byte_t := x"93";  -- implemented: Dostępy do nieistniejących adresów
    constant ADDR_ACQUISITION_STATE : byte_t := x"A0";  -- implemented: Stan akwizycji: 0 IDLE, 1 ARMED, 2 CAPTURE, 3 READY
    constant ADDR_ACQUISITION_WRITE_POINTER : byte_t := x"A1";  -- implemented: Bieżący wskaźnik zapisu
    constant ADDR_ACQUISITION_TRIGGER_POINTER : byte_t := x"A2";  -- implemented: Indeks próbki, w której nastąpiło wyzwolenie
    constant ADDR_ACQUISITION_SAMPLES : byte_t := x"A3";  -- planned: Zebrane próbki na kanał
    constant ADDR_ACQUISITION_RECORD_ID : byte_t := x"A4";  -- implemented: Numer ostatniego kompletnego rekordu
    constant ADDR_CHANNEL1_APPLIED_GAIN : byte_t := x"B0";  -- planned: Wzmocnienie aktywne, kanał 1
    constant ADDR_CHANNEL1_APPLIED_OFFSET : byte_t := x"B1";  -- planned: Offset aktywny, kanał 1
    constant ADDR_CHANNEL1_FLAGS : byte_t := x"B2";  -- planned: Przesterowanie ADC (lepkie), zajętość SPI (chwilowa), kanał 1
    constant ADDR_CHANNEL2_APPLIED_GAIN : byte_t := x"C0";  -- planned: Wzmocnienie aktywne, kanał 2
    constant ADDR_CHANNEL2_APPLIED_OFFSET : byte_t := x"C1";  -- planned: Offset aktywny, kanał 2
    constant ADDR_CHANNEL2_FLAGS : byte_t := x"C2";  -- planned: Przesterowanie ADC (lepkie), zajętość SPI (chwilowa), kanał 2
    constant ADDR_DEBUG_SCRATCH0 : byte_t := x"F0";  -- implemented: Rejestr roboczy, pierwszy test protokołu
    constant ADDR_DEBUG_SCRATCH1 : byte_t := x"F1";  -- implemented: Rejestr roboczy
    constant ADDR_DEBUG_LED : byte_t := x"F2";  -- implemented: Bity [7:0] sterują diodami na płytce
    constant ADDR_DEBUG_CONST : byte_t := x"F3";  -- implemented: Stała do testu odczytu
    constant VAL_DEBUG_CONST : word_t := x"DEADBEEF";

end package regmap_pkg;
