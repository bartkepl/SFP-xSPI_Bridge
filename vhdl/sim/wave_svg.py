"""Waveform figures (SVG) of the end-to-end tests for the documentation.

Usage (from vhdl/):  python sim/wave_svg.py [tb_e2e_spi tb_e2e_qspi ...]

Reads sim/out/<tb>_trace.txt written by sim/tb/e2e_bench.vhd and writes
doc/e2e/img/<test>_<figure>.svg:
  overview  - the whole test: host A, frames on the line, host B
  input     - pins of bridge A while host A sends the first frame
  link      - the first frame on the line A -> B (bits and 8b/10b characters)
  output    - pins of bridge B while host B receives the first frame

Trace format (times in fs):
  S <id> <name> <width>   V <t> <id> <value>   A <t0> <t1> <row> <text>   M <t> <marker>
"""

import os
import sys
from bisect import bisect_right

VHDL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(os.path.dirname(VHDL), 'doc', 'e2e', 'img')

NS = 1_000_000                      # fs per ns
US = 1000 * NS

C_BG, C_GRID, C_TXT, C_SIG, C_UND, C_ANN, C_ANN_K, C_MARK = (
    '#ffffff', '#e4e7ec', '#1f2328', '#1565c0', '#9aa4b2', '#e8f0fe', '#fde8d8', '#c62828')


class Trace:
    def __init__(self, path):
        self.names, self.width = {}, {}
        self.ch = {}                        # name -> ([t], [value])
        self.ann = {}                       # row -> [(t0, t1, text)]
        self.marks = []
        with open(path, encoding='utf-8') as f:
            for ln in f:
                p = ln.rstrip('\n').split(' ', 4)
                if p[0] == 'S':
                    self.names[p[1]] = p[2]
                    self.width[p[2]] = int(p[3])
                    self.ch[p[2]] = ([], [])
                elif p[0] == 'V':
                    ts, vs = self.ch[self.names[p[2]]]
                    t = int(p[1])
                    if ts and ts[-1] == t:
                        vs[-1] = p[3]
                    else:
                        ts.append(t)
                        vs.append(p[3])
                elif p[0] == 'A':
                    txt = p[4].strip() if len(p) > 4 else ''
                    self.ann.setdefault(p[3], []).append((int(p[1]), int(p[2]), txt))
                elif p[0] == 'M':
                    self.marks.append((int(p[1]), ln.split(' ', 2)[2].strip()))
        for r in self.ann.values():
            r.sort()

    def mark(self, name):
        for t, m in self.marks:
            if m == name:
                return t
        raise KeyError(name)

    def segments(self, name, bit, t0, t1):
        """[(ta, tb, char)] of one bit of a signal inside [t0, t1]."""
        ts, vs = self.ch[name]
        w = self.width[name]
        k = max(bisect_right(ts, t0) - 1, 0)
        out = []
        while k < len(ts) and ts[k] < t1:
            ta = max(ts[k], t0)
            tb = min(ts[k + 1], t1) if k + 1 < len(ts) else t1
            v = vs[k][w - 1 - bit] if bit is not None else vs[k]
            if out and out[-1][2] == v:
                out[-1] = (out[-1][0], tb, v)
            else:
                out.append((ta, tb, v))
            k += 1
        return out


def nice_step(span):
    for s in (1, 2, 5):
        for e in range(0, 13):
            st = s * 10 ** e * NS // 1000
            if st and span / st <= 12:
                return st
    return span


def fmt_t(t):
    if t >= US:
        return '%g µs' % round(t / US, 3)
    return '%g ns' % round(t / NS, 1)


def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def render(tr, path, title, t0, t1, rows, width=1500, marks=()):
    """rows: ('dig', label, signal, bit) | ('ann', label, row, kchars) | ('band', label, row)."""
    lw, rh, top = 150, 34, 46
    pw = width - lw - 20
    h = top + rh * len(rows) + 40
    sx = pw / (t1 - t0)

    def x(t):
        return lw + (t - t0) * sx

    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
         'font-family="Consolas, Menlo, monospace" font-size="12">' % (width, h),
         '<rect width="100%%" height="100%%" fill="%s"/>' % C_BG,
         '<text x="10" y="20" font-size="14" font-weight="bold" fill="%s">%s</text>' % (C_TXT, esc(title))]
    step = nice_step(t1 - t0)
    t = t0 + step
    while t < t1:
        o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="%s"/>' % (x(t), top - 8, x(t), h - 30, C_GRID))
        o.append('<text x="%.1f" y="%d" text-anchor="middle" fill="%s">%s</text>'
                 % (x(t), h - 14, C_TXT, fmt_t(t - t0)))
        t += step
    o.append('<text x="10" y="%d" fill="%s">od t = %s</text>' % (h - 14, C_TXT, fmt_t(t0 - t0 % NS)))
    for tm, lab in marks:
        if t0 <= tm <= t1:
            o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="%s" stroke-dasharray="4 3"/>'
                     % (x(tm), top - 8, x(tm), h - 30, C_MARK))
            o.append('<text x="%.1f" y="%d" fill="%s">%s</text>' % (x(tm) + 3, top - 12, C_MARK, esc(lab)))

    for i, r in enumerate(rows):
        y0 = top + i * rh
        yh, yl, ym = y0 + 6, y0 + rh - 8, y0 + rh / 2 - 1
        o.append('<text x="10" y="%.1f" fill="%s">%s</text>' % (ym + 4, C_TXT, esc(r[1])))
        if r[0] == 'dig':
            pts, und = [], []
            for ta, tb, v in tr.segments(r[2], r[3], t0, t1):
                if v in '1H':
                    y = yh
                elif v in '0L':
                    y = yl
                else:
                    y = ym
                if pts:
                    pts.append((x(ta), pts[-1][1]))
                pts.append((x(ta), y))
                pts.append((x(tb), y))
                if v in 'HZ':
                    und.append((x(ta), x(tb), y))
            if pts:
                o.append('<polyline fill="none" stroke="%s" stroke-width="1.5" points="%s"/>'
                         % (C_SIG, ' '.join('%.1f,%.1f' % p for p in pts)))
            for xa, xb, y in und:            # undriven (pull-up / high impedance)
                o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="3"/>'
                         % (xa, y, xb, y, C_UND))
        elif r[0] in ('ann', 'band'):
            kch = r[3] if len(r) > 3 else ()
            for ta, tb, txt in tr.ann.get(r[2], []):
                if tb < t0 or ta > t1:
                    continue
                xa, xb = x(max(ta, t0)), x(min(tb, t1))
                if xb - xa < 0.6:
                    continue
                fill = C_ANN_K if any(txt.startswith(k) for k in kch) else C_ANN
                o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%d" rx="3" fill="%s" stroke="%s" stroke-width="0.6"/>'
                         % (xa, yh, max(xb - xa, 0.6), rh - 14, fill, C_SIG))
                if r[0] == 'ann' and (xb - xa) > 7 * len(txt) + 4:
                    o.append('<text x="%.1f" y="%.1f" text-anchor="middle" fill="%s">%s</text>'
                             % ((xa + xb) / 2, ym + 4, C_TXT, esc(txt)))
    o.append('</svg>')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(o))


def with_ascii(tr, row):
    """Data characters: hex value plus the printable character."""
    out, prev = [], ''
    idle2 = {'50': 'D16.2', 'B5': 'D21.5', 'C5': 'D5.6'}   # second char of /I/ /P/ /R/
    for ta, tb, txt in tr.ann.get(row, []):
        orig = txt
        if prev == 'K28.5' and txt in idle2:
            txt = idle2[txt]
        elif len(txt) == 2:
            n = int(txt, 16)
            if 33 <= n <= 126:
                txt = txt + ' ' + chr(n)
        out.append((ta, tb, txt))
        prev = orig
    tr.ann[row] = out


def frames(tr, row):
    """Frames on the line from the character annotations: [(t_sof, t_eof_end)]."""
    out, start = [], None
    for ta, tb, txt in tr.ann.get(row, []):
        if txt == 'SOF':
            start = ta
        elif txt == 'EOF' and start is not None:
            out.append((start, tb))
            start = None
    return out


def make(tb):
    test = tb.replace('tb_e2e_', '')
    tr = Trace(os.path.join(VHDL, 'sim', 'out', tb + '_trace.txt'))
    os.makedirs(OUT_DIR, exist_ok=True)
    uart = test == 'uart'
    lines = {'spi': 1, 'qspi': 4, 'ospi': 8}.get(test, 0)
    up = test.upper()

    def io_rows(side):
        if uart:
            return [('dig', side + '.IO1 UART_TX' if side == 'B' else side + '.IO0 UART_RX', side + '.IO',
                     1 if side == 'B' else 0)]
        if lines == 1:
            return [('dig', side + '.IO0 (MOSI)', side + '.IO', 0), ('dig', side + '.IO1 (MISO)', side + '.IO', 1)]
        return [('dig', '%s.IO%d' % (side, b), side + '.IO', b) for b in range(lines - 1, -1, -1)]

    # frames on the line: A_TX characters; the frame of the first data
    fr = frames(tr, 'A_TX')
    t_end = tr.mark('end')
    marks = [(t, m) for t, m in tr.marks if m in ('link_up', 'end')]

    # overview
    if uart:
        rows = [('dig', 'A.HOST_IRQ_N', 'A.HOST_IRQ_N', None)] + io_rows('A') + [
            ('ann', 'A: znaki RX', 'A_IO'), ('band', 'linia: ramki', 'FRAMES')] + io_rows('B') + [
            ('ann', 'B: znaki TX', 'B_IO')]
    else:
        rows = [('dig', 'A.CS_N', 'A.CS_N', None), ('band', 'A: transakcje', 'A_IO'),
                ('band', 'linia: ramki', 'FRAMES'),
                ('dig', 'B.CS_N', 'B.CS_N', None), ('band', 'B: transakcje', 'B_IO')]
    tr.ann['FRAMES'] = [(a, b, 'ramka') for a, b in fr]
    t0 = tr.mark('link_up') - 2 * US
    render(tr, os.path.join(OUT_DIR, test + '_overview.svg'),
           'E2E %s ↔ %s: przebieg całego testu' % (up, up), t0, t_end, rows, marks=marks)

    # input of A
    if uart:
        ta, tb_ = tr.mark('a_in_start'), tr.mark('a_in_end')
    else:
        ta, tb_ = tr.mark('a_in_start_f0'), tr.mark('a_in_end_f0')
    pad = (tb_ - ta) // 40
    rows = ([] if uart else [('dig', 'A.SCLK', 'A.SCLK', None), ('dig', 'A.CS_N', 'A.CS_N', None)]) + \
        io_rows('A') + [('ann', 'A: dane', 'A_IO', ('TX_', 'RX_', 'READ', 'dummy', 'adr'))]
    render(tr, os.path.join(OUT_DIR, test + '_input.svg'),
           'Wejście mostka A (%s): host A wysyła ramkę „Hello, SFP!”' % up, ta - pad, tb_ + pad, rows)

    # link: first data frame after the input
    with_ascii(tr, 'A_TX')
    with_ascii(tr, 'B_RX')
    f1 = [f for f in fr if f[0] > ta][0]
    pad = 300 * NS
    rows = [('ann', 'A: znak nadany', 'A_TX', ('K', 'SOF', 'EOF', 'D16.2')),
            ('dig', 'linia A→B (TD+)', 'LINE_A_B', None),
            ('ann', 'B: znak odebrany', 'B_RX', ('K', 'SOF', 'EOF', 'D16.2'))]
    render(tr, os.path.join(OUT_DIR, test + '_link.svg'),
           'Łącze A → B (%s): ramka w kodzie 8b/10b, 100 Mbaud' % up, f1[0] - pad, f1[1] + 2 * pad, rows,
           width=2000)

    # output of B
    if uart:
        ann = tr.ann['B_IO']
        ta, tb_ = ann[0][0], ann[-1][1]
    else:
        ta = [t for t, m in tr.marks if m == 'b_out_start'][0]
        tb_ = [t for t, m in tr.marks if m == 'b_out_end'][0]
    pad = (tb_ - ta) // 40
    rows = ([] if uart else [('dig', 'B.SCLK', 'B.SCLK', None), ('dig', 'B.CS_N', 'B.CS_N', None)]) + \
        io_rows('B') + [('ann', 'B: dane', 'B_IO', ('TX_', 'RX_', 'READ', 'dummy', 'adr'))]
    render(tr, os.path.join(OUT_DIR, test + '_output.svg'),
           'Wyjście mostka B (%s): host B odbiera ramkę' % up, ta - pad, tb_ + pad, rows)
    print('ok', test)


if __name__ == '__main__':
    for tb in sys.argv[1:] or ['tb_e2e_spi', 'tb_e2e_qspi', 'tb_e2e_ospi', 'tb_e2e_uart']:
        make(tb)
