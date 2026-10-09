# Biblioteka C dla STM32

Biblioteka `sfp_bridge` obsługuje mostek SFP-xSPI z mikrokontrolera STM32: wymianę ramek, rejestry, przerwania, liczniki, pamięć i diagnostykę modułu SFP oraz przezroczysty tryb UART. Pliki: `firmware/sfp_bridge/`, przykład `firmware/examples/example_bridge.c`, testy `firmware/tests/`. Opis protokołu i rejestrów: [interfejs hosta (datasheet)](datasheet/index.md).

## 1 Cechy

- C11, bez dynamicznej alokacji; cały stan w strukturze `sfpb_t` (jedna na mostek, dowolna liczba mostków).
- Konfiguracja w czasie kompilacji przez `#define` w pliku `sfpb_config.h`: transport, liczba linii danych, uchwyty peryferiów, piny, funkcje włączane do kompilacji, limity czasu.
- Gotowe porty HAL: OCTOSPI (`HAL_OSPI`), XSPI (`HAL_XSPI`), QUADSPI (`HAL_QSPI`), SPI z programowym CS (`HAL_SPI`); opcjonalnie DMA. Własny transport przez strukturę `sfpb_port_t`.
- Obsługa wszystkich funkcji mostka: komendy `READ_ID`, `READ_STATUS`, `READ_REG`, `WRITE_REG`, `TX_WRITE_x`, `RX_READ_x`, `TX_ABORT`; rejestry `CTRL` (pętla zwrotna, wyłączenie lasera, `LOS_IGNORE`), przerwania i obsługa zdarzeń z wywołaniami zwrotnymi, liczniki błędów, polecenia I2C (odczyt i zapis pamięci A0h / A2h, identyfikacja modułu), diagnostyka DDM z przeliczeniem jednostek SFF-8472 (kalibracja wewnętrzna i zewnętrzna), progi alarmowe, `UART_DIV`, `MODE_CTRL` (tryb UART, RTS/CTS, echo ramek), `UART_STATUS`, reset programowy i sprzętowy (`HOST_RST_N`).

## 2 Struktura

```
firmware/
  sfp_bridge/
    include/sfp_bridge.h            API
    include/sfpb_regs.h             komendy xSPI, adresy i bity rejestrów
    include/sfpb_port.h             interfejs transportu (sfpb_port_t)
    include/sfpb_config_default.h   wartości domyślne konfiguracji
    config/sfpb_config_template.h   szablon sfpb_config.h
    src/sfp_bridge.c                transakcje, rejestry, ramki, zdarzenia, liczniki, UART
    src/sfpb_sfp.c                  I2C modułu, identyfikacja, DDM
    src/sfpb_internal.h             funkcje wewnętrzne
    port/sfpb_stm32.h               porty STM32 (kontekst, konstruktory)
    port/sfpb_port_stm32.c          wspólna część portów, port domyślny
    port/sfpb_port_ospi.c           HAL_OSPI
    port/sfpb_port_xspi.c           HAL_XSPI
    port/sfpb_port_qspi.c           HAL_QSPI
    port/sfpb_port_spi.c            HAL_SPI + GPIO CS
  examples/example_bridge.c         inicjalizacja, zdarzenia, DDM, sesja UART
  tests/                            testy na PC z modelem mostka
```

## 3 Włączenie do projektu

1. Dodać do projektu pliki `src/*.c` i `port/*.c` oraz ścieżki `include/`, `src/` i `port/`. Pliki portów niewybranych transportów kompilują się do pustych jednostek.
2. Skopiować `config/sfpb_config_template.h` jako `sfpb_config.h` do katalogu na ścieżce include i ustawić co najmniej `SFPB_TRANSPORT` oraz uchwyt peryferium (nazwa zmiennej globalnej z CubeMX, np. `hospi1`).
3. Skonfigurować peryferium w CubeMX zgodnie z tabelą 3.1, `HOST_IRQ_N` jako wejście EXTI (zbocze opadające, podciągnięcie), `HOST_RST_N` jako wyjście GPIO w stanie wysokim.
4. Po inicjalizacji HAL wywołać `sfpb_init(&dev, NULL)` (port domyślny z `sfpb_config.h`), w obsłudze EXTI `sfpb_irq_notify(&dev)`, w pętli głównej `sfpb_process(&dev, 0)`.

Plik konfiguracyjny jest wyszukiwany w kolejności: makro `SFPB_CONFIG_FILE` z wiersza poleceń kompilatora, `sfpb_config.h` na ścieżce include (kompilatory z `__has_include`), brak pliku — wymagane wtedy `SFPB_NO_CONFIG_FILE` (same wartości domyślne).

### 3.1 Ustawienia peryferium

| Parametr | OCTOSPI / XSPI | QUADSPI | SPI |
|---|---|---|---|
| tryb | pośredni (indirect), pamięć typu Micron / standard | pośredni (indirect) | master full-duplex, 8 bit, NSS programowy |
| zegar | ≤ 40 MHz (`ClockPrescaler`) | ≤ 40 MHz | zalecane ≤ 20 MHz |
| tryb zegara | 0 (SCLK niski w spoczynku) | 0 | CPOL = 0, CPHA = 0, MSB first |
| próbkowanie | `SampleShifting` = połowa cyklu | `SampleShifting` = połowa cyklu | zbocze narastające (stąd niższy zegar) |
| CS wysoki między transakcjami | `ChipSelectHighTime` ≥ 100 ns (4 cykle przy 40 MHz) | jw. | zapewniony przez czas wykonania kodu |
| linie IO | IO0…IO7 (`IOSelect` = IO[7:0] w XSPI) | IO0…IO3, bank 1 | MOSI = IO0, MISO = IO1 |

Przy 40 MHz próbkowanie danych mostka na zboczu narastającym ma budżet pół okresu ([datasheet, 4.2](datasheet/index.md#42-wymagania-czasowe-interfejsu-xspi)); dlatego OCTOSPI i QUADSPI pracują z przesunięciem próbkowania, a SPI — z niższym zegarem.

## 4 Konfiguracja

| Makro | Domyślnie | Znaczenie |
|---|---|---|
| `SFPB_TRANSPORT` | `SFPB_TRANSPORT_OSPI` | `_OSPI`, `_XSPI`, `_QSPI`, `_SPI` lub `_CUSTOM` (port przekazywany do `sfpb_init()`) |
| `SFPB_DATA_LINES` | 8 / 4 / 1 wg transportu | linie danych komend `TX_WRITE_x` / `RX_READ_x`; kontrola zgodności z transportem w czasie kompilacji |
| `SFPB_HAL_HEADER` | `"main.h"` | nagłówek HAL układu |
| `SFPB_OSPI_HANDLE`, `SFPB_XSPI_HANDLE`, `SFPB_QSPI_HANDLE`, `SFPB_SPI_HANDLE` | `hospi1`, `hxspi1`, `hqspi`, `hspi1` | uchwyt peryferium portu domyślnego |
| `SFPB_SPI_CS_PORT`, `SFPB_SPI_CS_PIN` | — | CS dla transportu SPI (wymagane) |
| `SFPB_RST_PORT`, `SFPB_RST_PIN` | — | `HOST_RST_N`; bez nich niedostępne `sfpb_hw_reset()` i `sfpb_mode_exit()` |
| `SFPB_USE_DMA`, `SFPB_DMA_MIN_LEN` | 0, 32 | DMA dla faz danych ≥ `SFPB_DMA_MIN_LEN` bajtów |
| `SFPB_HAL_TIMEOUT_MS` | 10 | limit czasu jednego wywołania HAL |
| `SFPB_USE_I2C` | 1 | polecenia I2C, identyfikacja modułu |
| `SFPB_USE_DDM` | 1 | rejestry DDM i przeliczenie jednostek |
| `SFPB_DDM_EXT_CAL` | 1 | kalibracja zewnętrzna SFF-8472 (arytmetyka `float`; wymaga `SFPB_USE_I2C`) |
| `SFPB_USE_FLOAT` | 1 | `sfpb_nw_to_dbm()` (`log10f`) |
| `SFPB_USE_UART` | 1 | `UART_DIV`, `MODE_CTRL`, `UART_STATUS`, echo ramek |
| `SFPB_USE_EVENTS` | 1 | `sfpb_process()` z wywołaniami zwrotnymi; bufor odbiorczy w `sfpb_t` |
| `SFPB_IRQ_MASK_DEFAULT` | `RX_FRAME` \| `LINK_CHG` \| `SFP_CHG` \| `ERR` (0 bez zdarzeń) | `IRQ_EN` po inicjalizacji |
| `SFPB_RX_BUF_SIZE` | 1024 | bufor ramki dla `sfpb_process()` |
| `SFPB_TIMEOUT_MS` | 100 | oczekiwanie na miejsce w FIFO TX w `sfpb_send()` |
| `SFPB_READY_TIMEOUT_MS` | 100 | oczekiwanie na `READ_ID` po resecie |
| `SFPB_I2C_TIMEOUT_MS` | 100 | jedno polecenie I2C |
| `SFPB_EEPROM_WRITE_MS` | 20 | ponawianie poleceń I2C zakończonych `NACK` (cykl zapisu EEPROM) |
| `SFPB_EEPROM_PAGE` | 8 | rozmiar strony EEPROM — zapis nie przekracza granicy strony |
| `SFPB_RESET_PULSE_MS` | 1 | czas impulsu `HOST_RST_N` (filtr mostka 640 ns) |

Kod biblioteki z portem (wszystkie funkcje, `-O2`, Cortex-M4): ok. 6,3 KB; bez I2C, DDM, UART i zdarzeń ok. połowy tej wartości. Pamięć RAM: `sfpb_t` ok. 1,1 KB ze zdarzeniami (bufor ramki `SFPB_RX_BUF_SIZE`), poniżej 100 B bez nich.

## 5 Warstwa portu

Port wykonuje jedną transakcję xSPI (CS niski … CS wysoki): instrukcja 8-bitowa na 1 linii, opcjonalny adres 8-bitowy na 1 linii, cykle dummy, faza danych na 1 / 4 / 8 liniach. W formatach 1-x-1 dane od hosta biegną linią IO0, do hosta — IO1.

```c
typedef struct sfpb_port {
    int      (*xfer)(void *ctx, const sfpb_cmd_t *cmd, uint8_t *data, size_t len);
    void     (*set_reset)(void *ctx, int asserted);   /* HOST_RST_N lub NULL */
    uint32_t (*get_ms)(void *ctx);
    void     (*delay_ms)(void *ctx, uint32_t ms);
    void     *ctx;
    uint8_t  max_lines;                                /* 1, 4 lub 8          */
} sfpb_port_t;
```

- `xfer` zwraca 0 albo wartość ujemną (błąd magistrali) i nie modyfikuje danych w kierunku zapisu.
- Port domyślny (`sfpb_port_default()`) powstaje z makr konfiguracji. Porty dla kolejnych mostków buduje się w czasie wykonania funkcjami `sfpb_port_ospi()`, `sfpb_port_xspi()`, `sfpb_port_qspi()`, `sfpb_port_spi()` z kontekstem `sfpb_stm32_ctx_t` (uchwyt, CS, `HOST_RST_N`); plik portu innego transportu niż `SFPB_TRANSPORT` włącza makro `SFPB_PORT_OSPI` / `_XSPI` / `_QSPI` / `_SPI` = 1.
- Własny transport (inna rodzina MCU, system operacyjny, magistrala współdzielona): `SFPB_TRANSPORT_CUSTOM` i własna struktura `sfpb_port_t`.

```c
static sfpb_stm32_ctx_t ctx_b = { &hospi2, NULL, 0, GPIOC, GPIO_PIN_3 };
sfpb_port_t port_b;
sfpb_port_ospi(&port_b, &ctx_b);
sfpb_init(&bridge_b, &port_b);
```

## 6 API

Funkcje zwracające `int` dają `SFPB_OK` (0) albo kod błędu z rozdziału 7; funkcje stanu (`sfpb_link_up()`, `sfpb_mode_sel()`, `sfpb_sfp_present()`) zwracają 1 / 0 albo kod błędu.

### 6.1 Inicjalizacja i reset

| Funkcja | Działanie |
|---|---|
| `sfpb_init(dev, port)` | inicjalizacja; `port` = NULL — port domyślny. Oczekuje na `READ_ID` (`5B 5F`), odczytuje `VERSION` (`dev->version`), zapisuje `IRQ_EN` i kasuje `IRQ_STAT` |
| `sfpb_wait_ready(dev, ms)` | ponawianie `READ_ID` do skutku lub upływu czasu |
| `sfpb_read_id(dev, &ver)` | `READ_ID` |
| `sfpb_hw_reset(dev)` | impuls `HOST_RST_N`, oczekiwanie na gotowość, odtworzenie `IRQ_EN`; powrót z trybu UART i echa |
| `sfpb_soft_reset(dev)` | `CTRL.SOFT_RST` (FIFO tracone, `MODE_CTRL` i `UART_DIV` zachowane), odtworzenie `IRQ_EN` |
| `sfpb_set_timeout(dev, ms)` | limit czasu `sfpb_send()` |
| `sfpb_set_data_lines(dev, n)` | linie danych 1 / 4 / 8 (≤ `max_lines` portu) |
| `sfpb_strerror(err)` | opis kodu błędu |

### 6.2 Rejestry i stan

| Funkcja | Działanie |
|---|---|
| `sfpb_read_regs(dev, adr, buf, n)` | `READ_REG`, 1–256 bajtów w jednej transakcji (spójny odczyt rejestrów wielobajtowych) |
| `sfpb_write_regs(dev, adr, buf, n)` | `WRITE_REG`, dzielone na transakcje po 8 bajtów |
| `sfpb_read_reg8()`, `sfpb_write_reg8()` | pojedynczy rejestr |
| `sfpb_read_status_fast(dev, &sf)` | `READ_STATUS` (`STATUS_FAST`) |
| `sfpb_get_status(dev, &st)` | `CTRL`, `STATUS`, `STATUS_FAST`, `IRQ_EN`, `IRQ_STAT`, `TX_SPACE`, `RX_LEVEL` w jednej transakcji |
| `sfpb_link_up(dev)`, `sfpb_wait_link(dev, ms)` | stan łącza `LINK_UP` |
| `sfpb_mode_sel(dev)` | stan zworki `MODE_SEL` |
| `sfpb_ctrl_update(dev, maska, wartość)` | odczyt–modyfikacja–zapis bitów 0–4 `CTRL`; skróty: `sfpb_set_tx_enable()`, `sfpb_set_rx_enable()`, `sfpb_set_loopback()`, `sfpb_set_laser_off()`, `sfpb_set_los_ignore()` |

### 6.3 Ramki

| Funkcja | Działanie |
|---|---|
| `sfpb_send(dev, type, data, len)` | ramka 1–1024 B: oczekiwanie na miejsce (`TX_READY` lub `TX_SPACE` ≥ `len` + 3) do limitu czasu urządzenia, zapis nagłówka i treści; przy błędzie transportu w fazie treści — `TX_ABORT` |
| `sfpb_send_timeout(..., ms)` | jw. z własnym limitem; 0 — bez oczekiwania |
| `sfpb_tx_space()`, `sfpb_wait_tx_empty()`, `sfpb_tx_abort()` | stan i sterowanie FIFO TX |
| `sfpb_recv(dev, &type, buf, max, &len)` | jedna ramka bez blokowania (`SFPB_ERR_EMPTY`, gdy brak); ramka dłuższa niż `max` jest odczytywana do końca, w buforze zostaje `max` bajtów, `len` = długość rzeczywista, wynik `SFPB_ERR_TRUNC` |
| `sfpb_recv_timeout(..., ms)` | jw. z oczekiwaniem |
| `sfpb_rx_level()` | `RX_LEVEL` |

Odbiór czyta `RX_LEVEL` tylko wtedy, gdy wyczerpie bajty znane z poprzedniego odczytu; ramka zajmuje dwie transakcje `RX_READ_x` (nagłówek, treść). Wysłanie ramki to `READ_STATUS` i dwie transakcje `TX_WRITE_x`.

### 6.4 Przerwania i zdarzenia

| Funkcja | Działanie |
|---|---|
| `sfpb_irq_enable(dev, maska)` | `IRQ_EN`; maska jest odtwarzana po każdym resecie |
| `sfpb_irq_read_clear(dev, &stat)` | odczyt `IRQ_STAT` i skasowanie odczytanych bitów (W1C) |
| `sfpb_irq_notify(dev)` | z obsługi EXTI `HOST_IRQ_N`; ustawia tylko znacznik |
| `sfpb_set_callbacks(dev, &cb, user)` | wywołania zwrotne: `rx_frame`, `link_change`, `sfp_change`, `tx_empty`, `i2c_done`, `error` |
| `sfpb_process(dev, poll)` | po zgłoszeniu przerwania (lub zawsze przy `poll` ≠ 0): `IRQ_STAT` + W1C, odbiór wszystkich ramek, wywołania zwrotne; zwraca obsłużone bity `IRQ_STAT` |

`sfpb_process()` po obsłudze sprawdza bit `STATUS_FAST.IRQ`: zdarzenie zgłoszone między odczytem a skasowaniem `IRQ_STAT` utrzymuje `HOST_IRQ_N` w stanie niskim bez nowego zbocza, więc znacznik jest ustawiany ponownie. Zmiana modułu SFP (`SFP_CHG`) unieważnia zapamiętane stałe kalibracji DDM. Wywołanie `error` otrzymuje `SFPB_ERR_LINK` dla bitu `ERR` (szczegóły w licznikach), `SFPB_ERR_TRUNC` i `SFPB_ERR_PROTO` z odbioru.

### 6.5 Liczniki

`sfpb_read_counters(dev, &cnt)` — osiem liczników 32-bitowych w jednej transakcji (`cnt.n.crc_err` lub `cnt.v[SFPB_CNT_CRC_ERR]`); `sfpb_clear_counters(dev)` — `CTRL.CNT_CLR` z zachowaniem pozostałych bitów `CTRL`.

### 6.6 Moduł SFP

| Funkcja | Działanie |
|---|---|
| `sfpb_sfp_read(dev, adr7, offset, buf, len)` | odczyt pamięci urządzenia I2C (`SFPB_SFP_A0` = 0x50, `SFPB_SFP_A2` = 0x51), `offset` + `len` ≤ 256, polecenia po 128 B |
| `sfpb_sfp_write(dev, adr7, offset, buf, len)` | zapis stronami `SFPB_EEPROM_PAGE`; polecenie zakończone `NACK` (cykl zapisu poprzedniej strony) ponawiane przez `SFPB_EEPROM_WRITE_MS` |
| `sfpb_sfp_info(dev, &info)` | identyfikacja A0h 0–95: typ, złącze, kodowanie, prędkość nominalna, długość fali, producent, numer części, rewizja, numer seryjny, data, typ diagnostyki, sumy kontrolne |
| `sfpb_sfp_present(dev)` | obecność modułu (`STATUS.MOD_ABS`) |
| `sfpb_ddm_raw(dev, &raw)` | rejestry DDM mostka (A2h 96–105 i 110, `DDM_STAT`, `DDM_SEQ`) |
| `sfpb_ddm_read(dev, &ddm)` | wartości w jednostkach: m°C, µV, µA, nW; `SFPB_ERR_NO_DDM` przed pierwszym odczytem modułu lub dla modułu bez diagnostyki |
| `sfpb_ddm_alarms(dev, &al)` | flagi alarmów i ostrzeżeń (A2h 112–113, 116–117) |
| `sfpb_ddm_set_period(dev, n)` | okres odczytu DDM × 100 ms (0 — wyłączony) |
| `sfpb_nw_to_dbm(nw)` | moc w dBm |

Kalibracja: przy pierwszym `sfpb_ddm_read()` po inicjalizacji, resecie lub zmianie modułu biblioteka odczytuje bajt 92 A0h. Dla kalibracji zewnętrznej (bit 4) odczytuje stałe A2h 56–91 i stosuje wzory SFF-8472: nachylenie (stałoprzecinkowe 8.8) i przesunięcie dla prądu i mocy nadajnika, temperatury i napięcia oraz wielomian 4. stopnia (`float`) dla mocy odbiornika.

### 6.7 Tryb UART i echo ramek

| Funkcja | Działanie |
|---|---|
| `sfpb_uart_div(baud)` | `UART_DIV` = zaokrąglenie 50 MHz / `baud`; 0 poza zakresem 8–65535 |
| `sfpb_uart_set_baud()`, `sfpb_uart_get_baud()` | `UART_DIV` (oba bajty w jednej transakcji) |
| `sfpb_uart_set_rtscts(dev, on)` | `MODE_CTRL.RTSCTS_EN` bez resetu mostka |
| `sfpb_uart_enter(dev, baud, rtscts)` | `UART_DIV`, potem `MODE_CTRL.UART_MODE` — mostek resetuje się i przechodzi w tryb UART z zadaną prędkością |
| `sfpb_echo_enter(dev)` | `MODE_CTRL.FRAME_ECHO` — odsyłanie odebranych ramek (test łącza z drugiej strony) |
| `sfpb_mode_exit(dev)` | powrót do trybu xSPI przez `HOST_RST_N` (`UART_DIV` wraca do 115 200 bit/s) |
| `sfpb_uart_status(dev, &st, clear)` | `UART_STATUS` z ostatniej sesji UART (`RX_OVF`, `FRAME_ERR`), opcjonalnie W1C |

W trybie UART i echa mostek nie odpowiada na komendy xSPI; biblioteka zwraca wtedy `SFPB_ERR_STATE` bez wykonywania transakcji, aż do `sfpb_mode_exit()` lub `sfpb_hw_reset()`. `UART_STATUS` przetrwa `HOST_RST_N`, więc po powrocie host odczytuje zdarzenia sesji UART.

## 7 Kody błędów

| Kod | Wartość | Znaczenie |
|---|---|---|
| `SFPB_OK` | 0 | powodzenie |
| `SFPB_ERR_IO` | −1 | błąd transportu (HAL) |
| `SFPB_ERR_TIMEOUT` | −2 | warunek nie spełniony w zadanym czasie |
| `SFPB_ERR_PARAM` | −3 | błędny argument |
| `SFPB_ERR_NO_DEVICE` | −4 | `READ_ID` nie zwraca `5B 5F` |
| `SFPB_ERR_EMPTY` | −5 | brak kompletnej ramki w FIFO RX |
| `SFPB_ERR_TRUNC` | −6 | ramka dłuższa niż bufor (reszta pominięta) |
| `SFPB_ERR_NACK` | −7 | I2C: brak potwierdzenia |
| `SFPB_ERR_BAD_CMD` | −8 | I2C: polecenie odrzucone (brak modułu, długość) |
| `SFPB_ERR_I2C_TIMEOUT` | −9 | I2C: SCL przytrzymany, magistrala zablokowana |
| `SFPB_ERR_NOT_SUPPORTED` | −10 | funkcja nieskonfigurowana (np. brak pinu `HOST_RST_N`) |
| `SFPB_ERR_STATE` | −11 | mostek w trybie UART lub echa |
| `SFPB_ERR_NO_DDM` | −12 | moduł bez diagnostyki lub brak danych |
| `SFPB_ERR_PROTO` | −13 | niepoprawny nagłówek ramki w FIFO RX (zalecany reset programowy) |
| `SFPB_ERR_LINK` | −14 | `IRQ_STAT.ERR`: błąd ramki na łączu lub bajt utracony przy pełnym FIFO TX |

## 8 Zasady użycia

- Wywołania dla jednej struktury `sfpb_t` nie mogą przebiegać współbieżnie; w systemie z wątkami dostęp chroni muteks aplikacji. Wyjątek: `sfpb_irq_notify()` (tylko znacznik, wywoływana z przerwania).
- Funkcje oczekujące (`sfpb_send()`, `sfpb_wait_*()`, polecenia I2C) odpytują mostek co 1 ms przez `delay_ms` portu; w systemie RTOS `delay_ms` portu własnego może oddawać procesor.
- Przy `SFPB_USE_DMA` = 1 bufory danych muszą być dostępne dla DMA; na rdzeniach z pamięcią podręczną danych (Cortex-M7, M55) spójność bufora zapewnia aplikacja (obszar niebuforowany lub operacje na pamięci podręcznej). Port czeka na zakończenie DMA aktywnie (stan uchwytu HAL), przerwania DMA i peryferium muszą być włączone.
- Ramki `TYPE` 0x01 są zarezerwowane dla trybu UART ([datasheet, 5.4](datasheet/index.md#54-format-ramki-w-buforach)).

## 9 Przykład

```c
#include "sfp_bridge.h"

static sfpb_t bridge;

static void on_frame(void *user, uint8_t type, const uint8_t *data, uint16_t len)
{
    /* ramka odebrana: type, data[0..len-1] */
}

static const sfpb_callbacks_t cb = { .rx_frame = on_frame };

void app_init(void)
{
    if (sfpb_init(&bridge, NULL) == SFPB_OK) {
        sfpb_set_callbacks(&bridge, &cb, NULL);
    }
}

void HAL_GPIO_EXTI_Falling_Callback(uint16_t pin)    /* HOST_IRQ_N; F4/L4: HAL_GPIO_EXTI_Callback */
{
    sfpb_irq_notify(&bridge);
}

void app_loop(void)
{
    static const char msg[] = "Hello, SFP!";
    sfpb_process(&bridge, 0);
    if (sfpb_link_up(&bridge) == 1) {
        sfpb_send(&bridge, SFPB_TYPE_DATA, msg, sizeof msg - 1);
    }
}
```

Pełny przykład (identyfikacja modułu, DDM, sesja UART z odczytem `UART_STATUS`): `firmware/examples/example_bridge.c`.

## 10 Weryfikacja

**Testy na PC** (`make -C firmware/tests`, gcc, C11, `-Wall -Wextra -Wpedantic -Wconversion -Werror`): biblioteka działa z modelem mostka na poziomie transakcji (`mock_bridge.c`). Model odwzorowuje mapę rejestrów z zatrzaskiem i W1C, FIFO TX z zatwierdzaniem ramek i `TX_ABORT`, FIFO RX, łącze między dwoma modelami i pętlę zwrotną, przerwania, liczniki, silnik I2C z pamięcią A0h / A2h, czasem zajętości i stronicowaniem EEPROM, rejestry DDM, `MODE_CTRL`, `UART_DIV`, `UART_STATUS` i `HOST_RST_N`. Każda transakcja jest sprawdzana z tabelą komend (linie danych, faza adresu, cykle dummy, kierunek, długość `WRITE_REG`). Wynik: 207 sprawdzeń, PASS.

| Grupa | Sprawdzenia |
|---|---|
| inicjalizacja | `VERSION`, `IRQ_EN`, brak mostka (`NO_DEVICE` po limicie czasu), port 4-liniowy, walidacja liczby linii, `sfpb_strerror()` |
| rejestry | zapis 16 B w dwóch transakcjach, odczyt, migawka stanu, oczekiwanie na łącze, modyfikacja bitów `CTRL` bez naruszania pozostałych |
| ramki | 1, 11, 255, 256, 1024 B na 8, 4 i 1 linii; kolejność i typ; obcięcie z zachowaniem następnej ramki; FIFO TX pełne przy braku łącza (limit czasu, granica `TX_SPACE` z nagłówkiem); opróżnienie po zestawieniu łącza; błąd transportu w treści → `TX_ABORT`; niespójny strumień RX → `PROTO` |
| zdarzenia | `LINK_CHG`, wiele ramek w jednym `sfpb_process()`, tryb odpytywania, `SFP_CHG`, `ERR`, odtworzenie `IRQ_EN` po resecie |
| SFP | identyfikacja z obcięciem spacji i sumami kontrolnymi, odczyt 256 B, zapis przez granicę strony z ponawianiem `NACK`, nieznane urządzenie, zajętość EEPROM ponad limit, zablokowany `BUSY`, brak modułu |
| DDM | jednostki przy kalibracji wewnętrznej, temperatura ujemna, kalibracja zewnętrzna (nachylenie, przesunięcie, wielomian mocy RX), moduł bez DDM, alarmy, dBm |
| UART | `UART_DIV` (zaokrąglenie, zakres), RTS/CTS bez resetu, wejście w tryb UART, blokada transakcji, powrót przez `HOST_RST_N`, `UART_STATUS` zachowany i kasowany W1C, tryb echa |
| liczniki | odczyt little-endian, `CNT_CLR` z zachowaniem `CTRL` |

**Test mutacyjny:** 17 wariantów błędów, wszystkie wykrywane — brak cykli dummy `RX_READ`, `WRITE_REG` powyżej 8 bajtów, brak `TX_ABORT`, odwrócona kolejność bajtów, brak odtworzenia `IRQ_EN`, brak rozliczania bajtów RX, sprawdzanie miejsca bez nagłówka, brak W1C, obcięcie zamiast zaokrąglenia `UART_DIV`, brak kasowania RTS/CTS, brak ponawiania `NACK`, zapis przez granicę strony, odwrócona kolejność współczynników wielomianu, zła skala temperatury, polecenie I2C ponad 128 B, pominięcie ramek w `sfpb_process()`, brak zgłoszenia obcięcia.

**Kompilacja portów** (`arm-none-eabi-gcc`, nagłówki STM32Cube, `-Wall -Wextra -Wconversion -Werror`, z DMA i bez):

| Transport | Układ | Pakiet STM32Cube |
|---|---|---|
| OCTOSPI (`HAL_OSPI`) | STM32L4R5 | FW_L4 1.18.2 |
| XSPI (`HAL_XSPI`) | STM32H563 | FW_H5 1.3.0 |
| QUADSPI (`HAL_QSPI`) | STM32F446, STM32L476 | FW_F4 1.28.3, FW_L4 1.18.2 |
| SPI (`HAL_SPI`) | STM32G0B1 | FW_G0 1.6.3 |

Konfiguracje z wyłączonymi funkcjami (`SFPB_USE_I2C`, `_DDM`, `_UART`, `_EVENTS`, `_FLOAT`, `SFPB_DDM_EXT_CAL` w różnych kombinacjach) kompilują się bez ostrzeżeń. Działanie na sprzęcie wymaga potwierdzenia na płytce rev. A.
