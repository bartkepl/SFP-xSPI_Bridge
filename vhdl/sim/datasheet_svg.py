"""Timing diagrams (SVG) for the host interface chapter (doc/datasheet/).

Usage (from vhdl/):  python sim/datasheet_svg.py

Idealized diagrams drawn from the protocol of xspi_slave / uart_bridge
(not from simulation). Wave language per lane, one character per cycle:
  p  clock period (low-high)     h / l  high / low      z  high impedance
  =  bus value (next label)      x  undefined           .  repeat previous
"""

import os

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                   'doc', 'datasheet', 'img')

C_BG, C_TXT, C_SIG, C_BUS, C_HOST, C_DEV, C_Z, C_ANN = (
    '#ffffff', '#1f2328', '#1565c0', '#e8f0fe', '#e8f5e9', '#fff3e0', '#9aa4b2', '#c62828')


def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def diagram(name, title, lanes, cyc=22, brackets=(), arrows=(), lw=120, note=None):
    """lanes: (label, wave, labels, colour) ; colour 'h' host / 'd' device / None."""
    n = max(len(w) for _, w, _, _ in lanes)
    rh, top = 34, 44
    width = lw + n * cyc + 20
    lines = note.split('|') if note else []
    width = max(width, int(max([len(t) for t in lines], default=0) * 6.7) + 24)
    h = top + rh * len(lanes) + 26 * (1 + max([b[3] for b in brackets], default=0)) + 16 * len(lines) + 6
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
         'font-family="Consolas, Menlo, monospace" font-size="11">' % (width, h),
         '<rect width="100%%" height="100%%" fill="%s"/>' % C_BG,
         '<text x="8" y="18" font-size="13" font-weight="bold" fill="%s">%s</text>' % (C_TXT, esc(title))]

    def x(c):
        return lw + c * cyc

    for i, (lab, wave, labels, col) in enumerate(lanes):
        y0 = top + i * rh
        yh, yl, ym = y0 + 5, y0 + rh - 9, y0 + (rh - 4) / 2
        o.append('<text x="8" y="%.1f" fill="%s">%s</text>' % (ym + 4, C_TXT, esc(lab)))
        li = iter(labels)
        prev = None
        c = 0
        segs = []
        while c < len(wave):
            ch = wave[c]
            if ch == '.':
                ch = prev
            if ch == '=' and (prev != '=' or wave[c] == '='):
                segs.append(['=', c, c + 1, next(li, '')])
            elif segs and segs[-1][0] == ch and ch != 'p':
                segs[-1][2] = c + 1
            else:
                segs.append([ch, c, c + 1, ''])
            prev = ch if wave[c] != '.' else prev
            c += 1
        fill = {'h': C_HOST, 'd': C_DEV}.get(col, C_BUS)
        lasty = None
        for k, (ch, a, b, txt) in enumerate(segs):
            xa, xb = x(a), x(b)
            if ch == 'p':
                pts = [(xa, yl), (xa + cyc / 2, yl), (xa + cyc / 2, yh), (xb, yh), (xb, yl)]
                o.append('<polyline fill="none" stroke="%s" stroke-width="1.4" points="%s"/>'
                         % (C_SIG, ' '.join('%.1f,%.1f' % p for p in pts)))
                lasty = yl
            elif ch in 'hl':
                y = yh if ch == 'h' else yl
                if lasty is not None and lasty != y:
                    o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="1.4"/>'
                             % (xa, lasty, xa, y, C_SIG))
                o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="1.4"/>'
                         % (xa, y, xb, y, C_SIG))
                lasty = y
            elif ch == 'z':
                o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="1.4" '
                         'stroke-dasharray="3 2"/>' % (xa, ym, xb, ym, C_Z))
                lasty = None
            elif ch in '=x':
                s = 3
                f = fill if ch == '=' else '#eceff1'
                pts = [(xa, ym), (xa + s, yh), (xb - s, yh), (xb, ym), (xb - s, yl), (xa + s, yl)]
                o.append('<polygon fill="%s" stroke="%s" stroke-width="1" points="%s"/>'
                         % (f, C_SIG, ' '.join('%.1f,%.1f' % p for p in pts)))
                if ch == 'x':
                    o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s"/>' % (xa + s, yl, xb - s, yh, C_Z))
                if txt and (xb - xa) > 6.5 * len(txt):
                    o.append('<text x="%.1f" y="%.1f" text-anchor="middle" fill="%s">%s</text>'
                             % ((xa + xb) / 2, ym + 4, C_TXT, esc(txt)))
                lasty = None
    yb = top + rh * len(lanes) + 6
    for a, b, txt, lvl in brackets:
        y = yb + lvl * 26
        o.append('<path d="M%.1f %.1f v6 H%.1f v-6" fill="none" stroke="%s"/>' % (x(a), y, x(b), C_TXT))
        o.append('<text x="%.1f" y="%.1f" text-anchor="middle" fill="%s">%s</text>'
                 % ((x(a) + x(b)) / 2, y + 19, C_TXT, esc(txt)))
    for c, lane, txt in arrows:
        xx = x(c)
        o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="%s" stroke-dasharray="4 3"/>'
                 % (xx, top - 4, xx, top + rh * len(lanes), C_ANN))
        o.append('<text x="%.1f" y="%d" fill="%s">%s</text>' % (xx + 3, top - 6, C_ANN, esc(txt)))
    for k, t in enumerate(lines):
        o.append('<text x="8" y="%d" fill="%s">%s</text>' % (h - 8 - 16 * (len(lines) - 1 - k), C_TXT, esc(t)))
    o.append('</svg>')
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name + '.svg'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(o))


def bits(v, n=8):
    return [str((v >> (n - 1 - i)) & 1) for i in range(n)]


def serial(values):
    """Bit-serial wave (h/l) for a list of bytes, MSB first."""
    w = ''
    for v in values:
        w += ''.join('h' if b == '1' else 'l' for b in bits(v))
    return w


def main():
    # ---- READ_REG: 0x0B, address, 8 dummy, data on IO1 -------------------------
    n_d = 2
    w_cs = 'h' + 'l' * (8 + 8 + 8 + 8 * n_d) + 'h'
    w_ck = 'l' + 'p' * (8 + 8 + 8 + 8 * n_d) + 'l'
    w_io0 = 'z' + serial([0x0B]) + serial([0x05]) + 'z' * (8 + 8 * n_d) + 'z'
    w_io1 = 'z' + 'z' * 24 + '=' * 8 + '=' * 8 + 'z'
    diagram('read_reg', 'READ_REG (0x0B), format 1-1-1: odczyt STATUS (0x05) i STATUS_FAST (0x06)', [
        ('CS_N', w_cs, [], None),
        ('SCLK', w_ck, [], None),
        ('IO0 (host)', w_io0, [], 'h'),
        ('IO1 (mostek)', w_io1, ['b%d' % i for i in range(7, -1, -1)] * 2, 'd'),
    ], cyc=17, brackets=[(1, 9, 'instrukcja 0x0B', 0), (9, 17, 'adres 0x05', 0),
                         (17, 25, '8 cykli dummy', 0), (25, 33, 'dane [0x05]', 0), (33, 41, 'dane [0x06]', 0)],
            note='Bity od najstarszego; host wystawia na zboczu opadającym, mostek próbkuje na narastającym.|'
                 'Adres zwiększa się po każdym bajcie.')

    # ---- WRITE_REG ----------------------------------------------------------------
    w_cs = 'h' + 'l' * 24 + 'h'
    w_ck = 'l' + 'p' * 24 + 'l'
    w_io0 = 'z' + serial([0x02, 0x07, 0x11]) + 'z'
    diagram('write_reg', 'WRITE_REG (0x02), format 1-1-1: zapis IRQ_EN (0x07) = 0x11', [
        ('CS_N', w_cs, [], None),
        ('SCLK', w_ck, [], None),
        ('IO0 (host)', w_io0, [], 'h'),
        ('IO1', 'z' * 26, [], None),
    ], cyc=16, brackets=[(1, 9, 'instrukcja 0x02', 0), (9, 17, 'adres 0x07', 0), (17, 25, 'dane 0x11', 0)],
            arrows=[(25.5, 0, 'zapis stosowany po podniesieniu CS_N')],
            note='Do 8 bajtów danych w jednej transakcji (adresy kolejne);|nadmiarowe bajty są pomijane.')

    # ---- TX_WRITE_4 ---------------------------------------------------------------
    payload = ['0x00 TYPE', '0x00 LEN_H', '0x03 LEN_L', "'A'", "'B'", "'C'"]
    w_cs = 'h' + 'l' * (8 + 12) + 'h'
    w_ck = 'l' + 'p' * (8 + 12) + 'l'
    w_io0 = 'z' + serial([0x32]) + '=' * 12 + 'z'
    w_io31 = 'z' + 'z' * 8 + '=' * 12 + 'z'
    nib = []
    for b in [0x00, 0x00, 0x03, 0x41, 0x42, 0x43]:
        nib += ['%X' % (b >> 4), '%X' % (b & 15)]
    diagram('tx_write_4', 'TX_WRITE_4 (0x32), format 1-0-4: ramka TYPE 0x00, LEN 3, treść „ABC”', [
        ('CS_N', w_cs, [], None),
        ('SCLK', w_ck, [], None),
        ('IO0', w_io0, nib, 'h'),
        ('IO[3:1]', w_io31, nib, 'h'),
    ], cyc=22, brackets=[(1, 9, 'instrukcja 0x32 (IO0)', 0)] +
       [(9 + 2 * i, 11 + 2 * i, p, 1 if i % 2 else 0) for i, p in enumerate(payload)],
            note='Tetrady na IO3..IO0, najpierw starsza.|Ramka jest zatwierdzana w FIFO TX po ostatnim bajcie treści.')

    # ---- RX_READ_8 ----------------------------------------------------------------
    w_cs = 'h' + 'l' * (8 + 8 + 6) + 'h'
    w_ck = 'l' + 'p' * (8 + 8 + 6) + 'l'
    w_io0 = 'z' + serial([0x8B]) + 'z' * 8 + '=' * 6 + 'z'
    w_io = 'z' + 'z' * 16 + '=' * 6 + 'z'
    vals = ['00', '00', '03', '41', '42', '43']
    diagram('rx_read_8', 'RX_READ_8 (0x8B), format 1-0-8: odczyt ramki z FIFO RX', [
        ('CS_N', w_cs, [], None),
        ('SCLK', w_ck, [], None),
        ('IO0', w_io0, vals, 'd'),
        ('IO[7:1]', w_io, vals, 'd'),
    ], cyc=22, brackets=[(1, 9, 'instrukcja 0x8B', 0), (9, 17, '8 cykli dummy', 0),
                         (17, 18, 'TYPE', 1), (18, 20, 'LEN', 0), (20, 23, 'treść', 1)],
            note='Bajt na takt na IO7..IO0.|Pusty FIFO zwraca 0x00; host czyta tyle bajtów, ile podaje RX_LEVEL.')

    # ---- READ_STATUS --------------------------------------------------------------
    w_cs = 'h' + 'l' * 24 + 'h'
    w_ck = 'l' + 'p' * 24 + 'l'
    w_io0 = 'z' + serial([0x05]) + 'z' * 16 + 'z'
    w_io1 = 'z' + 'z' * 8 + '=' * 8 + '=' * 8 + 'z'
    diagram('read_status', 'READ_STATUS (0x05), format 1-0-1: STATUS_FAST bez adresu i cykli dummy', [
        ('CS_N', w_cs, [], None),
        ('SCLK', w_ck, [], None),
        ('IO0 (host)', w_io0, [], 'h'),
        ('IO1 (mostek)', w_io1, ['STATUS_FAST'] * 8 + ['STATUS_FAST'] * 8, 'd'),
    ], cyc=16, brackets=[(1, 9, 'instrukcja 0x05', 0), (9, 17, 'STATUS_FAST', 0), (17, 25, 'powtórzenie', 0)])

    # ---- timing parameters --------------------------------------------------------
    diagram('timing', 'Parametry czasowe interfejsu xSPI (tryb 0)', [
        ('CS_N', 'hhllllllllllllhhhh', [], None),
        ('SCLK', 'lllpppppppppplllll', [], None),
        ('IO (host)', 'zz===========zzzzz', ['D'] * 11, 'h'),
        ('IO (mostek)', 'zzzzzz=======zzzzz', ['Q'] * 7, 'd'),
    ], cyc=30, brackets=[(2, 3.5, 't_CSS', 0), (13, 14, 't_CSH', 0), (14, 18, 't_CSW', 0), (3.5, 4.5, 't_SCLK', 1),
                     (3, 3.5, 't_SU', 2), (3.5, 4, 't_H', 3)],
            note='Wartości w tabeli „Wymagania czasowe”.|Mostek zatrzaskuje wejścia na zboczu narastającym, wyjścia zmienia na opadającym.')

    # ---- UART 8N1 -----------------------------------------------------------------
    b = 0x48
    w = 'hh' + 'l' + ''.join('h' if (b >> i) & 1 else 'l' for i in range(8)) + 'h' + 'hh'
    diagram('uart_8n1', 'UART 8N1: znak 0x48 („H”), najmłodszy bit pierwszy', [
        ('UART_RX', w, [], 'h'),
    ], cyc=34, brackets=[(2, 3, 'start', 0)] + [(3 + i, 4 + i, 'D%d' % i, 0) for i in range(8)] + [(11, 12, 'stop', 0)],
            note='Czas bitu = UART_DIV / 50 MHz (434 → 8,68 µs, 115 200 bit/s).|Próbkowanie w środku bitu.')


if __name__ == '__main__':
    main()
    print('ok', OUT)
