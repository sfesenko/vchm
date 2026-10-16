#!/usr/bin/env python3
"""LZX stream emitter for vchm unit tests: hand-checkable bit patterns in
exact on-wire order (16-bit LE words, MSB of each word first, MS-PATCH
2.1.1). Subcommands: vectors | block | selftest.
"""
import struct
import sys


class BitWriter:
    """Accumulates bits MSB-first, packs into 16-bit LE words."""

    def __init__(self):
        self.bits = []

    def put(self, n, val):
        for i in range(n - 1, -1, -1):
            self.bits.append((val >> i) & 1)

    def put_str(self, s):
        for c in s:
            self.bits.append(1 if c == "1" else 0)

    def pad_to_word(self):
        """Zero-pad to the next 16-bit boundary (CHM 0x8000 framing)."""
        while len(self.bits) % 16:
            self.bits.append(0)

    def finish(self):
        """Pack MSB-first into 16-bit LE words; zero-pad last word."""
        while len(self.bits) % 16:
            self.bits.append(0)
        out = bytearray()
        for i in range(0, len(self.bits), 16):
            w = 0
            for b in self.bits[i:i + 16]:
                w = (w << 1) | b
            out += bytes([w & 0xFF, (w >> 8) & 0xFF])
        return bytes(out)


class BitReader:
    """Independent Python reference reader (mirrors Itsf.Lzx.BitReader)."""

    def __init__(self, data):
        even = len(data) & ~1
        self.words = [data[i] | (data[i + 1] << 8)
                      for i in range(0, even, 2)]
        self.pos = 0
        self.total = even * 8

    def get(self, n):
        if self.pos + n > self.total:
            raise EOFError("bitstream overread")
        v = 0
        for _ in range(n):
            v = (v << 1) | ((self.words[self.pos // 16]
                             >> (15 - (self.pos % 16))) & 1)
            self.pos += 1
        return v


def build_table(lens):
    MAXB = 16
    bl = [0] * (MAXB + 1)
    for ln in lens:
        assert 0 <= ln <= MAXB
        if ln:
            bl[ln] += 1
    code = 0
    nxt = [0] * (MAXB + 1)
    for b in range(1, MAXB + 1):
        code = (code + bl[b - 1]) << 1
        nxt[b] = code
        assert code + bl[b] <= (1 << b), "oversubscribed"
    table = {}
    for b in range(1, MAXB + 1):
        for sym, ln in enumerate(lens):
            if ln == b:
                table[(nxt[b], b)] = sym
                nxt[b] += 1
    return table, max(lens) if lens else 0


def decode_sym(rd, table, ml):
    code = 0
    for b in range(1, ml + 1):
        code = (code << 1) | rd.get(1)
        if (code, b) in table:
            return table[(code, b)]
    raise EOFError("bad prefix")


def pretree_lengths(rd, count, prev=None):
    """Decode `count` lengths delta-coded against `prev` (MS-PATCH 2.5:
    Len[x] = (prev[x] - code + 17) % 17; 17/18 zero-runs; 19 value-run
    with a further pretree-coded symbol)."""
    if prev is None:
        prev = [0] * count
    assert len(prev) == count
    pre = [rd.get(4) for _ in range(20)]
    if all(v == 0 for v in pre):
        return [0] * count
    table, ml = build_table(pre)
    out = []
    while len(out) < count:
        s = decode_sym(rd, table, ml)
        x = len(out)
        if s <= 16:
            out.append((prev[x] - s + 17) % 17)
        elif s in (17, 18):
            n = rd.get(4 if s == 17 else 5)
            run = (4 if s == 17 else 20) + n
            if len(out) + run > count:
                raise EOFError("run overrun")
            out += [0] * run
        else:
            same = rd.get(1)
            s2 = decode_sym(rd, table, ml)
            if s2 > 16:
                raise EOFError("bad 19 second code")
            v = (prev[x] - s2 + 17) % 17
            if len(out) + 4 + same > count:
                raise EOFError("run overrun")
            out += [v] * (4 + same)
    return out


def msb_first_vector():
    """Bits 1,0,1,0,0,0,... then a full 0x1234 word."""
    w = BitWriter()
    w.put(16, 0xA000)
    w.put(16, 0x1234)
    return w.finish()


def two_symbol_vector():
    """Bits 0,1,... (symbols 0 then 1 under lengths [1, 1])."""
    w = BitWriter()
    w.put_str("01")
    return w.finish()


def pretree_runs_vector():
    """Pretree codes 19, 17, 18 in one stream -> [16]*5 + [0]*24."""
    w = BitWriter()
    pre = [2, 2] + [0] * 15 + [2, 3, 3]
    assert len(pre) == 20
    for nb in pre:
        w.put(4, nb)
    w.put_str("111")   # 19
    w.put(1, 1)        # same = 1 -> 5 copies
    w.put_str("01")    # s2 = sym 1 -> value (0-1+17)%17 = 16
    w.put_str("10")    # 17
    w.put(4, 0)        # +0 -> 4 zeros
    w.put_str("110")   # 18
    w.put(5, 0)        # +0 -> 20 zeros
    return w.finish()


def uncompressed_block(payload, r0=1, r1=1, r2=1, e8=False):
    """Type-3 (uncompressed) block: E8 bit, type 011, pad, R0/R1/R2 LE
    DWORDs, raw payload, word-aligned. No size field (unlike LZXD);
    the decoder takes the expected length out of band."""
    w = BitWriter()
    w.put(1, 1 if e8 else 0)
    w.put_str("011")  # block type 3 = uncompressed
    data = bytearray(w.finish())  # padded to one word
    data += struct.pack("<III", r0, r1, r2)
    data += payload
    if len(data) % 2:
        data += b"\x00"
    return bytes(data)


# --- Verbatim-block encoder (MS-PATCH 2.3.1/2.3.2.2/2.5/2.6) --------------
# Uniform-length trees (valid by construction); pretrees use flat 5-bit
# lengths over the delta symbols that occur.

_SLOT_BASE = [0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192,
              256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144,
              8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304,
              131072, 196608, 262144, 393216, 524288, 655360, 786432,
              917504, 1048576]
_SLOT_FBITS = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
               9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16,
               16, 17, 17, 17, 17, 17, 17, 17]


def _slot_for(formatted):
    for s in range(len(_SLOT_BASE) - 1, -1, -1):
        if formatted >= _SLOT_BASE[s]:
            span = 1 << _SLOT_FBITS[s] if _SLOT_FBITS[s] else 1
            if formatted < _SLOT_BASE[s] + span:
                return s
    raise ValueError("no slot for %d" % formatted)


def _canonical_codes(lens):
    """symbol -> (code, length) under canonical assignment."""
    bl = [0] * 17
    for ln in lens:
        if ln:
            bl[ln] += 1
    code = 0
    codes = {}
    for b in range(1, 17):
        code = (code + bl[b - 1]) << 1
        nxt = code
        for sym, ln in enumerate(lens):
            if ln == b:
                codes[sym] = (nxt, b)
                nxt += 1
    return codes


def _uniform_lengths(nsyms, used):
    """Length L for every used symbol; Kraft-safe for any used set."""
    if not used:
        return [0] * nsyms
    import math
    L = max(1, (len(used) - 1).bit_length())
    lens = [0] * nsyms
    for s in used:
        lens[s] = L
    return lens


def _delta_codes(lens):
    """Delta-code sequence for a length list (prev starts at 0)."""
    codes = []
    prev = 0
    for ln in lens:
        codes.append((prev - ln + 17) % 17)
        prev = ln
    return codes


def _pretree_codes(pre):
    """Canonical codes for a 20-symbol pretree: sym -> (code, len)."""
    bl = [0] * 17
    for x in pre:
        if x:
            bl[x] += 1
    code = 0
    out = {}
    for b in range(1, 17):
        code = (code + bl[b - 1]) << 1
        nxt = code
        for sym, x in enumerate(pre):
            if x == b:
                out[sym] = (nxt, b)
                nxt += 1
    return out


def _emit_tree(w, lens, prev):
    """Pretree-coded lengths with 17/18/19 runs (MS-PATCH 2.5); delta is
    (prev[x] - len + 17) % 17, 19's second symbol pretree-coded."""
    assert len(prev) == len(lens)
    if all(l == 0 for l in lens):
        for _ in range(20):
            w.put(4, 0)
        return
    toks = []  # ints 0..16, or (17/18, count, width), or (19, same, delta)
    i, n = 0, len(lens)
    while i < n:
        ln = lens[i]
        j = i
        while j < n and lens[j] == ln:
            j += 1
        run = j - i
        if ln == 0 and run >= 4:
            while run >= 4:
                if run >= 20:
                    take = min(run, 51)
                    toks.append((18, take - 20, 5))
                else:
                    take = min(run, 19)
                    toks.append((17, take - 4, 4))
                i += take
                run -= take
            while run > 0:
                toks.append((prev[i] - 0 + 17) % 17)
                i += 1
                run -= 1
            continue
        if ln != 0 and run >= 4:
            while run >= 5:
                toks.append((19, 1, (prev[i] - ln + 17) % 17))
                i += 5
                run -= 5
            if run == 4:
                toks.append((19, 0, (prev[i] - ln + 17) % 17))
                i += 4
                run -= 4
        while run > 0:
            toks.append((prev[i] - ln + 17) % 17)
            i += 1
            run -= 1
    used = set()
    for t in toks:
        if isinstance(t, int):
            used.add(t)
        else:
            used.add(t[0])
            if t[0] == 19:
                used.add(t[2])
    pre = [0] * 20
    for s in sorted(used):
        pre[s] = 5
    for nb in pre:
        w.put(4, nb)
    pc = _pretree_codes(pre)
    for t in toks:
        if isinstance(t, int):
            code, bl = pc[t]
            w.put(bl, code)
        elif t[0] in (17, 18):
            code, bl = pc[t[0]]
            w.put(bl, code)
            w.put(t[2], t[1])
        else:
            code, bl = pc[19]
            w.put(bl, code)
            w.put(1, t[1])
            code, bl = pc[t[2]]
            w.put(bl, code)


def _split_long (tokens):
    """Explode matches longer than 257 into <=257 chunks (same offset).

    CHM LZX has no Extra Length field (black-box verified against the
    reference decoder: a length-tree 248 is exactly 257); real archives
    encode long matches as back-to-back matches, so the machine-generated
    vectors must do the same. Splitting here, before slot resolution,
    yields the same R0-repeat chains real encoders emit. Splitting is
    byte-exact for overlapping matches too (periodic extension continues
    across chunk boundaries exactly as one match would).
    """
    out = []
    for tok in tokens:
        if isinstance (tok, int):
            out.append (tok)
            continue
        off, ln = tok
        while ln > 257:
            # Never leave a remainder of 1 (minimum match length is 2).
            chunk = 256 if ln - 257 == 1 else 257
            out.append ((off, chunk))
            ln -= chunk
        out.append ((off, ln))
    return out


def _emit_verbatim(w, tokens, window_bits, e8, prev=None, out_base=0,
                   first=True):
    """Append one verbatim block's bits to `w` (no word padding).

    out_base is the global output count at this block's start, so
    0x8000 word-padding lands on output multiples across blocks.
    Tree lengths delta against prev (a (main1, main2, len) triple of
    previous-block trees, or None for zeros). Returns the new triple
    for chaining.
    """
    tokens = _split_long (tokens)
    slots = window_bits * 2
    main_count = 256 + 8 * slots
    # Pass 1: resolve matches to (slot, header, footer, length_sym|None).
    r = [1, 1, 1]
    main_used = set()
    len_used = set()
    resolved = []
    for tok in tokens:
        if isinstance(tok, int):
            main_used.add(tok)
            resolved.append(tok)
            continue
        off, ln = tok
        if off == r[0]:
            slot = 0
        elif off == r[1]:
            slot = 1
            r[0], r[1] = r[1], r[0]
        elif off == r[2]:
            slot = 2
            r[0], r[2] = r[2], r[0]
        else:
            f = off + 2
            slot = _slot_for(f)
            r[2], r[1], r[0] = r[1], r[0], off
        header = ln - 2 if ln <= 8 else 7
        sym = 256 + (slot << 3) + header
        assert sym < main_count, (sym, main_count)
        main_used.add(sym)
        lsym = None
        if header == 7:
            lsym = (ln - 9) if ln <= 257 else 248
            assert 0 <= lsym <= 248
            len_used.add(lsym)
        resolved.append((off if slot >= 3 else None, slot, header, lsym, ln))
    main_lens = _uniform_lengths(main_count, main_used)
    len_lens = _uniform_lengths(249, len_used)
    main_codes = _canonical_codes(main_lens)
    len_codes = _canonical_codes(len_lens)
    # Pass 2: E8 bit (first block only), 3-bit type, 24-bit size
    # (plain-LZX CHM framing: no default-size flag, no extended byte).
    if first:
        w.put(1, 1 if e8 else 0)
    w.put_str("001")  # block type 1 = verbatim
    out_len = 0
    for tok in tokens:
        out_len += 1 if isinstance(tok, int) else tok[1]
    assert 0 < out_len <= 0xFFFFFF
    w.put(24, out_len)
    if prev is None:
        p1 = [0] * 256
        p2 = [0] * (main_count - 256)
        pl = [0] * 249
    else:
        p1, p2, pl = prev
    _emit_tree(w, main_lens[:256], p1)
    _emit_tree(w, main_lens[256:], p2)
    _emit_tree(w, len_lens, pl)
    r = [1, 1, 1]
    out_count = 0
    for tok, res in zip(tokens, resolved):
        if isinstance(tok, int):
            code, bl = main_codes[tok]
            w.put(bl, code)
            out_count += 1
            if (out_base + out_count) % 0x8000 == 0:
                w.pad_to_word()
            continue
        off, slot, header, lsym, ln = res
        code, bl = main_codes[256 + (slot << 3) + header]
        w.put(bl, code)
        if header == 7:
            code, bl = len_codes[lsym]
            w.put(bl, code)
        if slot >= 3:
            f = off + 2
            base = _SLOT_BASE[slot]
            w.put(_SLOT_FBITS[slot], f - base)
        # R update mirrors pass 1 (encoder-side state for the next token).
        if off == r[0]:
            pass
        elif off == r[1]:
            r[0], r[1] = r[1], r[0]
        elif off == r[2]:
            r[0], r[2] = r[2], r[0]
        else:
            r[2], r[1], r[0] = r[1], r[0], off
        # No Extra Length field: 248 is exactly 257 (split above).
        out_count += ln
        if (out_base + out_count) % 0x8000 == 0:
            w.pad_to_word()
    return (main_lens[:256], main_lens[256:], len_lens)


def verbatim_block(tokens, window_bits=15, e8=False):
    """Type-1 (verbatim) block from int literals / (offset, length)
    matches; lengths > 257 split into chunks (no Extra Length field)."""
    w = BitWriter()
    _emit_verbatim(w, tokens, window_bits, e8)
    return w.finish()


def verbatim_stream(blocks, window_bits=15, e8=False):
    """Verbatim blocks bit-packed; trees chain, E8 bit on first only."""
    w = BitWriter()
    base = 0
    prev = None
    first = True
    for tokens in blocks:
        prev = _emit_verbatim(w, tokens, window_bits, e8, prev,
                              out_base=base, first=first)
        first = False
        base += sum(1 if isinstance(t, int) else t[1] for t in tokens)
    return w.finish()


def genvectors (outdir):
    """Write the committed unit-test vectors (deterministic recipes)."""
    import os
    os.makedirs (outdir, exist_ok=True)
    hello = b"hello lzx world\n" * 64
    open (os.path.join (outdir, "type3_hello.lzx"), "wb").write (
        uncompressed_block (hello))
    abcd = [ord (c) for c in "abcd"] * 4
    open (os.path.join (outdir, "verbatim_abcd.lzx"), "wb").write (
        verbatim_block (abcd, window_bits=15))
    mtoks = [ord ('a'), ord ('b'), (2, 198)]
    open (os.path.join (outdir, "verbatim_match.lzx"), "wb").write (
        verbatim_block (mtoks, window_bits=15))
    pay = bytes ([0, 0, 0, 0, 0, 0xE8, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    open (os.path.join (outdir, "e8code.lzx"), "wb").write (
        uncompressed_block (pay, e8=True))
    # Aligned block with a split footer (offset 1000 needs verbatim +
    # aligned bits) and an R0 repeat.
    # NOTE: offsets must be <= emitted; build a prefix then match into it.
    prefix = list (b"0123456789abcdef" * 70)  # 1120 bytes
    atoks = prefix + [(1000, 20), (1000, 12)]
    aexp = bytes (prefix)
    for off, ln in [(1000, 20), (1000, 12)]:
        for i in range (ln):
            aexp += bytes ([aexp[len (aexp) - off]])
    open (os.path.join (outdir, "aligned_foo.lzx"), "wb").write (
        aligned_block (atoks, window_bits=15))
    open (os.path.join (outdir, "aligned_foo.exp"), "wb").write (aexp)
    # Chained two-block stream: R0/R1/R2 reuse, long (>257, split)
    # lengths, high slots, and a 0x8000 realignment crossing.
    import random
    random.seed (5)
    alphabet = (b"abcdefghijklmnopqrstuvwxyz"
                b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<> /=\"\n")
    def gen (nbytes):
        toks = []
        out = bytearray ()
        chunk = bytes (random.choice (alphabet) for _ in range (2000))
        toks += list (chunk)
        out += chunk
        while len (out) < nbytes:
            off = random.choice ([500, 700, 1000, 2000, 5000])
            ln = random.choice ([10, 50, 100, 200, 300, 500])
            if off > len (out) or len (out) + ln > nbytes + 600:
                continue
            toks.append ((off, ln))
            for i in range (ln):
                out.append (out[len (out) - off])
        return toks, bytes (out)
    t1, e1 = gen (20000)
    t2, e2 = gen (20000)
    open (os.path.join (outdir, "verbatim_big.lzx"), "wb").write (
        verbatim_stream ([t1, t2], window_bits=16))
    open (os.path.join (outdir, "verbatim_big.exp"), "wb").write (e1 + e2)
    print ("wrote vectors to %s" % outdir)


def aligned_block(tokens, window_bits=15, e8=False):
    """Type-2 (aligned) block (MS-PATCH 2.3.2.3/2.6.3): verbatim shape plus
    an 8x3-bit aligned tree; footers >= 3 bits split verbatim/aligned."""
    tokens = _split_long (tokens)
    slots = window_bits * 2
    main_count = 256 + 8 * slots
    r = [1, 1, 1]
    main_used = set()
    len_used = set()
    aligned_used = set()
    resolved = []
    for tok in tokens:
        if isinstance(tok, int):
            main_used.add(tok)
            resolved.append(tok)
            continue
        off, ln = tok
        if off == r[0]:
            slot = 0
        elif off == r[1]:
            slot = 1
            r[0], r[1] = r[1], r[0]
        elif off == r[2]:
            slot = 2
            r[0], r[2] = r[2], r[0]
        else:
            f = off + 2
            slot = _slot_for(f)
            r[2], r[1], r[0] = r[1], r[0], off
        header = ln - 2 if ln <= 8 else 7
        sym = 256 + (slot << 3) + header
        assert sym < main_count, (sym, main_count)
        main_used.add(sym)
        lsym = None
        if header == 7:
            lsym = (ln - 9) if ln <= 257 else 248
            assert 0 <= lsym <= 248
            len_used.add(lsym)
        footer = None
        aligned = None
        if slot >= 3:
            base = _SLOT_BASE[slot]
            fb = _SLOT_FBITS[slot]
            foot = (off + 2) - base
            if fb >= 3:
                footer = foot >> 3
                aligned = foot & 7
                aligned_used.add(aligned)
            else:
                footer = foot
        resolved.append((slot, header, lsym, footer, aligned, ln, off))
    main_lens = _uniform_lengths(main_count, main_used)
    len_lens = _uniform_lengths(249, len_used)
    main_codes = _canonical_codes(main_lens)
    len_codes = _canonical_codes(len_lens)
    # Aligned tree: every symbol length 3 (complete by construction).
    aligned_codes = {s: (s, 3) for s in range(8)}
    w = BitWriter()
    w.put(1, 1 if e8 else 0)
    w.put_str("010")  # block type 2 = aligned
    out_len = sum(1 if isinstance(t, int) else t[1] for t in tokens)
    assert 0 < out_len <= 0xFFFFFF
    w.put(24, out_len)
    for _ in range(8):
        w.put(3, 3)
    z256 = [0] * 256
    _emit_tree(w, main_lens[:256], z256)
    _emit_tree(w, main_lens[256:], [0] * (main_count - 256))
    _emit_tree(w, len_lens, [0] * 249)
    r = [1, 1, 1]
    out_count = 0
    for tok, res in zip(tokens, resolved):
        if isinstance(tok, int):
            code, bl = main_codes[tok]
            w.put(bl, code)
            out_count += 1
            if out_count % 0x8000 == 0:
                w.pad_to_word()
            continue
        slot, header, lsym, footer, aligned, ln, off = res
        code, bl = main_codes[256 + (slot << 3) + header]
        w.put(bl, code)
        if header == 7:
            code, bl = len_codes[lsym]
            w.put(bl, code)
        if slot >= 3:
            fb = _SLOT_FBITS[slot]
            if fb >= 3:
                w.put(fb - 3, footer)
                code, bl = aligned_codes[aligned]
                w.put(bl, code)
            else:
                w.put(fb, footer)
        if off == r[0]:
            pass
        elif off == r[1]:
            r[0], r[1] = r[1], r[0]
        elif off == r[2]:
            r[0], r[2] = r[2], r[0]
        else:
            r[2], r[1], r[0] = r[1], r[0], off
        # No Extra Length field: 248 is exactly 257 (split above).
        out_count += ln
        if out_count % 0x8000 == 0:
            w.pad_to_word()
    return w.finish()


def vala_literal(data):
    return "{ %s }" % ", ".join("0x%02X" % b for b in data)


def selftest():
    # MSB-first vector: word 0xA000 then 0x1234.
    v = msb_first_vector()
    assert v == bytes([0x00, 0xA0, 0x34, 0x12]), vala_literal(v)
    rd = BitReader(v)
    assert rd.get(1) == 1
    assert rd.get(1) == 0
    assert rd.get(1) == 1
    assert rd.get(3) == 0
    assert rd.get(10) == 0
    assert rd.get(16) == 0x1234
    try:
        rd.get(1)
        raise SystemExit("overread did not throw")
    except EOFError:
        pass
    # Odd tail carries no bits (word-aligned streams per MS-PATCH 2.1.1).
    try:
        BitReader(bytes([0xFF])).get(1)
        raise SystemExit("odd tail readable")
    except EOFError:
        pass
    # Single- and two-symbol Huffman tables.
    t, ml = build_table([1, 0, 0, 0])
    rd = BitReader(bytes([0x00, 0x00]))
    assert decode_sym(rd, t, ml) == 0
    assert decode_sym(rd, t, ml) == 0
    t, ml = build_table([1, 1])
    rd = BitReader(two_symbol_vector())
    assert two_symbol_vector() == bytes([0x00, 0x40])
    assert decode_sym(rd, t, ml) == 0
    assert decode_sym(rd, t, ml) == 1
    # All-zero pretree.
    rd = BitReader(bytes(10))
    assert pretree_lengths(rd, 256) == [0] * 256
    # Pretree run codes 19 / 17 / 18 (tree-delta against zeros).
    rd = BitReader(pretree_runs_vector())
    assert pretree_lengths(rd, 29) == [16] * 5 + [0] * 24, \
        vala_literal(pretree_runs_vector())
    # Type-3 block: E8 bit + 011, pad, R0/R1/R2, payload, word aligned.
    blk = uncompressed_block(b"abc")
    assert len(blk) % 2 == 0
    rd = BitReader(blk)
    assert rd.get(1) == 0
    assert rd.get(3) == 3
    assert rd.get(12) == 0
    assert blk[2:14] == struct.pack("<III", 1, 1, 1)
    assert blk[14:17] == b"abc"
    # Verbatim block, literal-only: decode back through the reader.
    lit = [ord(c) for c in "abcd"] * 4
    vb = verbatim_block(lit, window_bits=15)
    rd = BitReader(vb)
    assert rd.get(1) == 0 and rd.get(3) == 1
    assert rd.get(24) == 16
    m1 = pretree_lengths(rd, 256)
    m2 = pretree_lengths(rd, 240)
    assert all(v == 0 for v in m2)
    lt = pretree_lengths(rd, 249)
    assert all(v == 0 for v in lt)
    mt, ml = build_table(m1 + m2)
    got = [decode_sym(rd, mt, ml) for _ in lit]
    assert got == lit, (got, lit)
    # Verbatim block with a match: literals plus one (offset, length).
    toks = [ord('a'), ord('b'), (2, 10)]
    vb2 = verbatim_block(toks, window_bits=15)
    rd = BitReader(vb2)
    assert rd.get(1) == 0 and rd.get(3) == 1
    assert rd.get(24) == 12
    m1 = pretree_lengths(rd, 256)
    m2 = pretree_lengths(rd, 240)
    lt = pretree_lengths(rd, 249)
    mt, ml = build_table(m1 + m2)
    ltt, ltml = build_table(lt), max(lt)
    assert decode_sym(rd, mt, ml) == ord('a')
    assert decode_sym(rd, mt, ml) == ord('b')
    msym = decode_sym(rd, mt, ml)
    assert msym >= 256, msym
    print("mklzx selftest: all checks passed")


def main(argv):
    if argv[1:] == ["selftest"]:
        selftest()
    elif argv[1:] == ["vectors"]:
        print("msb_first:  %s" % vala_literal(msb_first_vector()))
        print("two_symbol: %s" % vala_literal(two_symbol_vector()))
        print("pretree_runs: %s" % vala_literal(pretree_runs_vector()))
        print("block(abc): %s" % vala_literal(uncompressed_block(b"abc")))
    elif len(argv) == 4 and argv[1] == "block":
        with open(argv[2], "rb") as f:
            payload = f.read()
        with open(argv[3], "wb") as f:
            f.write(uncompressed_block(payload))
        print("wrote %d-byte type-3 block" % len(uncompressed_block(payload)))
    elif len(argv) == 3 and argv[1] == "genvectors":
        genvectors (argv[2])
    else:
        raise SystemExit("usage: mklzx.py {selftest|vectors|block IN OUT|genvectors DIR}")


if __name__ == "__main__":
    main(sys.argv)
