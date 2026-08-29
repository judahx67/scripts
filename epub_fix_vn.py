"""Fix publisher-side text encoding defects in an EPUB.

Three things go wrong before a book ever reaches a device:

  * the file isn't really UTF-8 (mislabelled cp1252/latin-1 bytes)
  * the text is mojibake (UTF-8 that was decoded as cp1252/latin-1 and re-saved)
  * the text is NFD or mixed normalization, so tone marks are separate codepoints

A bitmap-glyph renderer has no mark positioning, so decomposed Vietnamese cannot
compose no matter what the font covers. All three are fixed here, in that order.

    uv run --python 3.12 python fix_epub.py book.epub
    uv run --python 3.12 python fix_epub.py --dry-run *.epub
    uv run --python 3.12 python fix_epub.py            # self-check
"""
import os
import re
import sys
import unicodedata
import zipfile

TEXT = ('.xhtml', '.html', '.htm', '.opf', '.ncx', '.css', '.smil')
DECL = re.compile(r'(<\?xml[^>]*?encoding=["\'])([\w-]+)(["\'])', re.I)
META = re.compile(r'(<meta[^>]*charset=["\']?)([\w-]+)', re.I)


def decode(data):
    """Return (text, encoding). EPUB requires UTF-8; fall back for mislabelled files."""
    for enc in ('utf-8', 'cp1252', 'latin-1'):
        try:
            return data.decode(enc), enc
        except UnicodeDecodeError:
            continue
    return data.decode('utf-8', 'replace'), 'utf-8/replace'


def demojibake(t, nbsp_repair=False):
    """Undo latin-1 mojibake, converting only runs that really are one.

    Damage can be selective -- one word may hold both an intact 'e-acute' and a
    doubled 'a-acute' -- so a blanket .encode('latin-1').decode('utf-8') corrupts
    the healthy characters. This walks sequence by sequence instead.

    nbsp_repair additionally recovers a U+00A0 that a downstream whitespace pass
    flattened to a space or deleted. Leave it OFF for publisher files: a heading
    like "LOI GIA TU" legitimately holds an accented capital before a space, and
    treating that space as a lost NBSP silently corrupts it. fix_optimized.py
    turns it on because the optimizer provably does destroy U+00A0.
    """
    return _scan(t, nbsp_repair)[0]


def _scan(t, nbsp_repair=False):
    """demojibake(), also returning how many sequences were converted."""
    out, fixed = [], 0
    i, n = 0, len(t)
    while i < n:
        o = ord(t[i])
        need = 2 if 0xC2 <= o <= 0xDF else 3 if 0xE0 <= o <= 0xEF else 4 if 0xF0 <= o <= 0xF4 else 0
        if need:
            bs, j, guessed = [o], i + 1, False
            while len(bs) < need:
                oj = ord(t[j]) if j < n else -1
                if 0x80 <= oj <= 0xBF:
                    bs.append(oj); j += 1                    # intact continuation
                elif nbsp_repair and oj == 0x20:
                    bs.append(0xA0); j += 1; guessed = True  # NBSP flattened to a space
                elif nbsp_repair and len(bs) == need - 1:
                    bs.append(0xA0); guessed = True          # NBSP deleted outright
                else:
                    break
            if len(bs) == need:
                try:
                    ch = bytes(bs).decode('utf-8')
                    if not guessed or _plausible(ord(ch)):
                        out.append(ch); i = j; fixed += 1; continue
                except UnicodeDecodeError:
                    pass
        out.append(t[i]); i += 1
    return ''.join(out), fixed


def _plausible(o):
    """Codepoints Latin/Vietnamese text actually uses -- guards the ambiguous guess."""
    return 0xA0 <= o <= 0x24F or 0x1E00 <= o <= 0x1EFF or 0x2000 <= o <= 0x206F


def retag(t):
    """Point any encoding declaration at UTF-8, since that is what we write."""
    t = DECL.sub(lambda m: m.group(1) + 'utf-8' + m.group(3), t)
    return META.sub(lambda m: m.group(1) + 'utf-8', t)


def marks(t):
    return sum(1 for c in t if unicodedata.combining(c))


def fix_text(t):
    """Return (text, report) for one document."""
    r = {}
    t, recovered = _scan(t)
    if recovered:
        r['mojibake'] = recovered
    before = marks(t)
    t = unicodedata.normalize('NFC', t)
    if before > marks(t):
        r['decomposed'] = before - marks(t)
    return retag(t), r


def fix(src, dry_run=False):
    dst = f'{os.path.splitext(src)[0]}-fixed.epub'
    total, files, encodings = {}, 0, set()
    out = None if dry_run else zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED)
    try:
        with zipfile.ZipFile(src) as zin:
            for it in zin.infolist():
                data = zin.read(it.filename)
                if it.filename.lower().endswith(TEXT):
                    t, enc = decode(data)
                    if enc != 'utf-8':
                        encodings.add(enc)
                    t, r = fix_text(t)
                    if r:
                        files += 1
                        for k, v in r.items():
                            total[k] = total.get(k, 0) + v
                    data = t.encode('utf-8')
                if out:
                    # pass the ZipInfo through so mimetype stays STORED and first
                    out.writestr(it, data)
    finally:
        if out:
            out.close()

    name = os.path.basename(src)
    if not total and not encodings:
        print(f'{name}: clean, nothing to fix')
        if out and os.path.exists(dst):
            os.remove(dst)
        return None
    bits = []
    if encodings:
        bits.append('not UTF-8 (' + ', '.join(sorted(encodings)) + ')')
    if total.get('mojibake'):
        bits.append(f"{total['mojibake']} mojibake chars")
    if total.get('decomposed'):
        bits.append(f"{total['decomposed']} combining marks")
    print(f"{name}: {', '.join(bits)} across {files} files"
          + ('  [dry run]' if dry_run else f'\n  -> {os.path.basename(dst)}'))
    return None if dry_run else dst


def demo():
    def epub(path, body):
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', zipfile.ZIP_STORED)
            z.writestr('c.xhtml', '<?xml version="1.0" encoding="utf-8"?><p>' + body + '</p>')

    good = 'Bé gái, nhà văn, khoảng 10 tuổi'
    checks = {
        'nfd': unicodedata.normalize('NFD', good),
        'mojibake': good.encode('utf-8').decode('latin-1'),
        'clean': good,
    }
    for name, body in checks.items():
        epub(f'_t_{name}.epub', body)
        dst = fix(f'_t_{name}.epub')
        if name == 'clean':
            assert dst is None, 'clean file should need no fixing'
        else:
            got = zipfile.ZipFile(dst).read('c.xhtml').decode('utf-8')
            assert good in got, (name, got)
            assert zipfile.ZipFile(dst).getinfo('mimetype').compress_type == zipfile.ZIP_STORED
            os.remove(dst)
        os.remove(f'_t_{name}.epub')
    # text that merely contains latin-1 accents must never be "repaired"
    for clean in ('Ana María', 'LỜI GIÃ TỪ', 'TRẢ THÙ 1', 'Ô hô! Ai tai!'):
        assert demojibake(clean) == clean, clean
    # ... but a real NBSP inside a mojibake run is still a valid continuation byte
    assert demojibake('nhà văn'.encode('utf-8').decode('latin-1')) == 'nhà văn'
    print('ok')


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    if not args:
        demo()
    else:
        for a in args:
            fix(a, dry_run='--dry-run' in sys.argv)
