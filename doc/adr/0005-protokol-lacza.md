# 0005. Protokół łącza: ramka z CRC-32 bez retransmisji, kontrola przepływu XON/XOFF w sekwencji bezczynności

**Stan:** przyjęta, uzupełniona przez [ADR 0008](0008-stan-lacza.md) (para bezczynności /R/ — odbiornik niezsynchronizowany) · **Data:** 2026-10-08
**Dotyczy:** vhdl, firmware, doc

## Kontekst

Łącze przenosi ramki danych między dwoma mostkami z prędkością 100 Mbaud (8b/10b, ok. 9 MB/s danych). Do ustalenia były:

1. reakcja na ramkę uszkodzoną (błąd CRC, błąd kodu 8b/10b, niezgodna długość),
2. postępowanie, gdy odbiorca nie nadąża odczytywać danych z FIFO odbiorczego (przy 9 MB/s FIFO 4 kB zapełnia się w ok. 0,5 ms),
3. format ramki i rozróżnianie jej typów.

## Rozważane warianty

**Ramki uszkodzone:**
(a) potwierdzenia i retransmisja w FPGA (ARQ) — wymaga bufora retransmisji i numeracji ramek;
(b) odrzucenie ramki w FPGA i zgłoszenie błędu do STM32; o ponowieniu decyduje oprogramowanie.

**Przepełnienie odbiornika:**
(a) odrzucanie nowych ramek i zliczanie strat;
(b) sygnał wstrzymania nadawania (XOFF) przesyłany do strony przeciwnej.

## Decyzja

**Ramki uszkodzone — wariant (b).** FPGA nie retransmituje. Ramka z błędem jest w całości odrzucana z FIFO odbiorczego (cofnięcie wskaźnika zapisu do ostatniej zatwierdzonej ramki), zwiększany jest odpowiedni licznik (CODE_ERR, DISP_ERR, CRC_ERR, LEN_ERR, OVERFLOW) i zgłaszane przerwanie ERR. Ponowienie należy do oprogramowania STM32.

**Przepełnienie — wariant (b), XON/XOFF w sekwencji bezczynności.** Stan wstrzymania jest przesyłany ciągle, jako rodzaj pary bezczynności, a nie jako jednorazowe zdarzenie — utrata pojedynczego symbolu nie gubi stanu.

**Format strumienia:**

| Element | Symbole | Znaczenie |
|---|---|---|
| Bezczynność /I/ (XON) | K28.5 D16.2 | nadawanie dozwolone; para przywraca RD− (jak /I2/ w 1000BASE-X) |
| Bezczynność /P/ (XOFF) | K28.5 D21.5 | strona przeciwna nie może rozpoczynać nowych ramek |
| Ramka | K27.7 · TYPE · LEN_H · LEN_L · treść · CRC[0..3] · K29.7 | zob. niżej |

- Między ramkami występuje co najmniej jedna para bezczynności (aktualizacja stanu XON/XOFF i wyrównanie do comma).
- `LEN` — długość treści w bajtach, 1…1024 (0 i > 1024 niedozwolone).
- CRC-32 (IEEE 802.3, [moduł `crc32`](../vhdl/crc32.md)) obejmuje TYPE, LEN_H, LEN_L i treść; bajty CRC od najmłodszego.
- `TYPE`: `0x00` — dane użytkownika; `0x01`–`0x0F` — zarezerwowane dla sterowania łączem; `0x10`–`0xFF` — typy definiowane przez aplikację, przekazywane do hosta bez interpretacji.
- Nadajnik rozpoczyna ramkę tylko wtedy, gdy cała ramka jest w FIFO nadawczym (brak przerw wewnątrz ramki) i strona przeciwna nie zgłasza XOFF. Ramka rozpoczęta jest zawsze dokończona.
- Odbiornik zgłasza XOFF, gdy wolne miejsce w FIFO odbiorczym spada poniżej progu uwzględniającego ramkę w trakcie odbioru i ramkę, którą strona przeciwna mogła rozpocząć przed odebraniem XOFF (próg i histereza są parametrami modułu).

## Konsekwencje

- Brak bufora retransmisji i numeracji ramek — mniejsze zużycie BSRAM i logiki.
- Biblioteka C (`sfpb_*`) udostępnia liczniki błędów i przerwanie ERR; mechanizm ponowień (np. potwierdzenia na poziomie aplikacji) pozostaje w gestii oprogramowania.
- FIFO odbiorcze musi obsługiwać zatwierdzanie i odrzucanie ramki (`commit` / `abort`); ten sam mechanizm w FIFO nadawczym realizuje zasadę „nadawanie tylko pełnych ramek”.
- Przy XOFF przepustowość spada do zera do czasu odczytu danych przez hosta; dane nie są tracone, dopóki host w ogóle czyta.
- Pole TYPE pozwala aplikacji multipleksować strumienie bez zmian w FPGA.
