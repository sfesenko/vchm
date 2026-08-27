#!/usr/bin/env python3
"""Build two small .chm test fixtures for the vCHM test suite.

book_cp1251.chm  — Ukrainian book encoded in CP1251 (most common)
book_koi8u.chm   — Ukrainian book encoded in KOI8-U

Features exercised:
  • Cyrillic page content (searchable words: кобзар, київ, мова)
  • Table of contents (HHC, nested) + binary #TOCIDX
  • Keyword index (HHK + $WWKeywordLinks/BTree)
  • Full-text search ($FIftiMain with ASCII words)
  • Small embedded image (PNG)
  • HTML entities (&laquo;, &raquo;, &mdash;, &Ntilde;)
  • <h1>/<h2> headings for flat-TOC label extraction
  • Inter-page links (navigation test)
"""
import os, struct, sys, zlib

sys.path.insert(0, os.path.dirname(__file__))
from mkfixtures import (build, tlv_system, topic_entries, btree_unit,
                        fts_unit, reset_table)


def tiny_png():
    sig = b"\x89PNG\r\n\x1a\n"
    def chunk(typ, data):
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0)
    raw = b""
    for y in range(4):
        raw += b"\x00"
        for x in range(4):
            raw += bytes([200 + y*10, 40 + x*30, 60])
    idat = zlib.compress(raw)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def enc(text, codec):
    """Encode unicode text to the target codec."""
    return text.encode(codec)


def page(title, h1, h2, body, extra="", codec="cp1251"):
    """Build an HTML page with the given content in the target encoding."""
    parts = [
        b"<html>\n<head>\n",
        b'<meta http-equiv="Content-type" content="text/html; charset=',
        codec.encode("ascii"), b'">\n',
        b"<title>", enc(title, codec), b"</title>\n",
        b"</head>\n<body>\n<h1>", enc(h1, codec), b"</h1>\n",
    ]
    if h2:
        parts += [b"<h2>", enc(h2, codec), b"</h2>\n"]
    parts += [b"<p>", enc(body, codec), b"</p>\n"]
    if extra:
        parts += [enc(extra, codec)]
    parts += [b"</body>\n</html>\n"]
    return b"".join(parts)


def build_book(outdir, name, codec, lcid, home, chaps, toc_pairs,
               hhc, hhk, btree_specs, fts_words):
    sysb = tlv_system(title="vCHM Test Book".encode("utf-8"),
                      home="home.htm", hhc="toc.hhc", hhk="index.hhk",
                      lcid=lcid)
    topics, strings, urltbl, urlstr = topic_entries(toc_pairs)

    n = len(toc_pairs)
    nsz = 24
    root = 4
    tocidx = bytearray()
    for i in range(n + 1):
        nxt = root + nsz * (i + 1) if i < n else 0
        flags = 0x4 if i == 0 else 0x8
        tidx = 0xFFFFFFFF if i == 0 else i - 1
        child = root + nsz if i == 0 else 0
        b = bytearray(nsz)
        struct.pack_into("<I", b, 0, nxt)
        struct.pack_into("<I", b, 4, flags)
        struct.pack_into("<I", b, 8, tidx)
        struct.pack_into("<I", b, 0x14, child)
        tocidx += bytes(b)

    files = {
        "::DataSpace/Storage/MSCompressed/ResetTable": reset_table(),
        "::DataSpace/Storage/MSCompressed/Content": b"\x00" * 16,
        "/#SYSTEM": sysb,
        "/#TOPICS": topics, "/#STRINGS": strings,
        "/#URLTBL": urltbl, "/#URLSTR": urlstr,
        "/#TOCIDX": bytes(tocidx),
        "/toc.hhc": hhc.encode("utf-8"),
        "/index.hhk": hhk.encode("utf-8"),
        "/$WWKeywordLinks/BTree": btree_unit(btree_specs),
        "/$FIftiMain": fts_unit(fts_words, topics_count=n, node_len=2048, r=7),
        "/home.htm": home,
        "/img/cover.png": tiny_png(),
    }
    for pname, pbytes in chaps:
        files["/" + pname] = pbytes

    path = os.path.join(outdir, name)
    build(path, files)
    print(f"  {name} ({os.path.getsize(path)} bytes)")


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    c = "cp1251"
    print("Building test fixtures:")

    # ── CP1251 book ──────────────────────────────────────────────────────
    home_cp = page(
        title="Довідник vCHM",
        h1="Довідник vCHM",
        h2="Світлина",
        body="Ця книга перевіряє читання CHM-архівів.",
        extra='<ul>\n'
            '  <li><a href="ch1.htm">Розділ 1</a></li>\n'
            '  <li><a href="ch2.htm">Розділ 2</a></li>\n'
            '  <li><a href="ch3.htm">Розділ 3</a></li>\n'
            '</ul>\n'
            '<img src="img/cover.png" alt="обкладинка" width="64" height="64">\n'
            '<p>&laquo;Кобзар&raquo; &mdash; збірка Тараса Шевченка.</p>\n',
        codec=c,
    )

    ch1 = page(
        title="Вступ до «Кобзаря»",
        h1="Розділ 1. Вступ",
        h2="Що таке «Кобзар»?",
        body="«Кобзар» — збірка поезій Тараса Шевченка.",
        extra='<h2>Київ і Дніпро</h2>\n'
            '<p>Київ — столиця України, а Дніпро тече через місто.</p>\n'
            '<pre>\nКобзар\n( збірка поезій )\n</pre>\n'
            '<h2>Мова і слово</h2>\n'
            '<p>Українська мова має мелодійну будову. '
            'Кобзар — народний співець.</p>\n'
            '<p><a href="../home.htm">На головну</a></p>\n',
        codec=c,
    )

    ch2 = page(
        title="Мова і пісня",
        h1="Розділ 2. Мова і пісня",
        h2="Народна творчість",
        body="Пісня — душа українського народу.",
        extra='<h2>Народна пісня</h2>\n'
            '<p>Пісня — скарб народної мудрості.</p>\n'
            '<p><a href="ch1.htm">Попередній розділ</a></p>\n',
        codec=c,
    )

    ch3 = page(
        title="Письменники України",
        h1="Розділ 3. Письменники",
        h2="Леся Українка",
        body="Леся Українка — видатна поетеса.",
        extra='<h2>Григорій Сковорода</h2>\n'
            '<p>Сковорода — філософ і поет.</p>\n'
            '<p><a href="../home.htm">На головну</a></p>\n',
        codec=c,
    )

    toc_cp = [
        ("Довідник vCHM", "home.htm"),
        ("Розділ 1. Вступ", "ch1.htm"),
        ("Розділ 2. Мова", "ch2.htm"),
        ("Розділ 3. Письменники", "ch3.htm"),
    ]

    hhc_cp = (
        "<html><body>\n<UL>\n"
        '  <LI><OBJECT type="text/sitemap">'
        '<param name="Name" value="Довідник vCHM">'
        '<param name="Local" value="home.htm"></OBJECT>\n'
        "  <UL>\n"
        '    <LI><OBJECT type="text/sitemap">'
        '<param name="Name" value="Розділ 1">'
        '<param name="Local" value="ch1.htm"></OBJECT>\n'
        '    <LI><OBJECT type="text/sitemap">'
        '<param name="Name" value="Розділ 2">'
        '<param name="Local" value="ch2.htm"></OBJECT>\n'
        '    <LI><OBJECT type="text/sitemap">'
        '<param name="Name" value="Розділ 3">'
        '<param name="Local" value="ch3.htm"></OBJECT>\n'
        "  </UL>\n</UL></BODY></HTML>"
    )

    hhk_cp = (
        "<html><body><UL>\n"
        '  <LI><OBJECT type="text/sitemap">'
        '<param name="Name" value="кобзар">'
        '<param name="Local" value="ch1.htm"></OBJECT>\n'
        '  <LI><OBJECT type="text/sitemap">'
        '<param name="Name" value="шевченко">'
        '<param name="Local" value="ch1.htm"></OBJECT>\n'
        '  <LI><OBJECT type="text/sitemap">'
        '<param name="Name" value="мова">'
        '<param name="Local" value="ch3.htm"></OBJECT>\n'
        '  <LI><OBJECT type="text/sitemap">'
        '<param name="Name" value="київ">'
        '<param name="Local" value="ch2.htm"></OBJECT>\n'
        "</UL></BODY></HTML>"
    )

    build_book(outdir, "book_cp1251.chm", c, 0x0422,
               home_cp, [("ch1.htm", ch1), ("ch2.htm", ch2), ("ch3.htm", ch3)],
               toc_cp, hhc_cp, hhk_cp,
               [("kobzar", [0, 1, 2], None), ("shevchenko", [0, 1], None),
                ("language", [2], None), ("song", [3], None)],
               [("kobzar", 0, [0, 1, 2]), ("shevchenko", 0, [0, 1]),
                ("language", 0, [2]), ("song", 0, [3])])

    # ── KOI8-U book ──────────────────────────────────────────────────────
    k = "koi8-u"
    home_k = page(
        title="Кодування КОІ8-У",
        h1="Кодування КОІ8-У",
        h2="Світлина",
        body="Ця книга перевіряє кодування КОІ8-У.",
        extra='<ul>\n  <li><a href="ch1.htm">Розділ 1</a></li>\n</ul>\n'
            '<img src="img/cover.png" width="64" height="64">\n'
            '<p>&laquo;Ґанок&raquo; &mdash; українське слово.</p>\n',
        codec=k,
    )

    ch1k = page(
        title="Вступ",
        h1="Розділ 1. Вступ",
        h2="Що таке КОІ8-У?",
        body="Київ &mdash; столиця України. Їжак і ґанок &mdash; українські слова.",
        extra='<h2>Літери</h2>\n'
            '<p>Українські літери: і, ї, є, ґ.</p>\n'
            '<p><a href="../home.htm">На головну</a></p>\n',
        codec=k,
    )

    build_book(outdir, "book_koi8u.chm", k, 0x0422,
               home_k, [("ch1.htm", ch1k)],
               [("Кодування КОІ8-У", "home.htm"), ("Розділ 1", "ch1.htm")],
               "<html><body><UL>"
               '<LI><OBJECT type="text/sitemap"><param name="Name" value="Кодування">'
               '<param name="Local" value="home.htm"></OBJECT>'
               '<LI><OBJECT type="text/sitemap"><param name="Name" value="Розділ 1">'
               '<param name="Local" value="ch1.htm"></OBJECT>'
               "</UL></BODY></HTML>",
               "<html><body><UL>"
               '<LI><OBJECT type="text/sitemap"><param name="Name" value="їжак">'
               '<param name="Local" value="ch1.htm"></OBJECT>'
               "</UL></BODY></HTML>",
               [("koi8u", [0, 1], None), ("encoding", [0, 1], None)],
               [("koi8u", 0, [0, 1]), ("encoding", 0, [0, 1])])


if __name__ == "__main__":
    outdir = sys.argv[1] if len(sys.argv) > 1 else "tests/fixtures"
    main(outdir)
