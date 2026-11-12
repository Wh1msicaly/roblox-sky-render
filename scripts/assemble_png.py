"""Rebuild PNG files from roblox-sky-render's no-HTTP export.

    python assemble_png.py --out <output_dir> [--run <id>] [search_dir_or_file ...]

shared.SkyExportPart (scripts/export_nohttp.luau) returns fixed-size text pieces that are too big
for Claude Code to show, so Claude Code saves each one to tool-results/<something>.txt. This script
finds the pieces for one export run, checks them, decodes them and writes <name>.png.

Search locations default to ~/.claude/projects (every session's tool-results folder). Without
--run it uses the most recent run it finds. Standard library only.

Decoding is the encoder in reverse: 7-bit characters -> LZW codes (9..16 bits, 256 = clear,
257 = end) -> filtered bytes -> undo the "Sub" filter -> RGBA pixels, checked against CRC-32.
"""
import argparse
import glob
import json
import os
import re
import struct
import sys
import zlib

MAGIC = "SKYB128 1 "
CLEAR, STOP, FIRST, LIMIT = 256, 257, 258, 65536
HEADER = re.compile(
    r"SKYB128 1 run=(?P<run>[0-9a-f]+) part=(?P<part>\d+) of=(?P<of>\d+) w=(?P<w>\d+) h=(?P<h>\d+) "
    r"crc=(?P<crc>[0-9a-f]{8}) plen=(?P<plen>\d+) pcrc=(?P<pcrc>[0-9a-f]{8}) name=(?P<name>.+)"
)


def piece_text(path):
    """Return the piece text from a saved tool result, or None if the file is not a piece."""
    with open(path, "rb") as f:
        head = f.read(16)
        if not (head.startswith(MAGIC.encode()) or head[:1] in (b"[", b"{")):
            return None
        raw = head + f.read()
    text = raw.decode("utf-8", errors="strict") if raw.isascii() else None
    if text is None:
        return None
    if text.startswith(MAGIC):
        return text
    try:  # some clients save results as JSON content blocks
        data = json.loads(text)
    except ValueError:
        return None
    blocks = data if isinstance(data, list) else data.get("content", [data]) if isinstance(data, dict) else []
    for b in blocks:
        t = b.get("text") if isinstance(b, dict) else None
        if isinstance(t, str) and t.startswith(MAGIC):
            return t
    return None


def read_piece(path):
    text = piece_text(path)
    if text is None:
        return None
    nl = text.find("\n")
    m = HEADER.fullmatch(text[:nl]) if nl > 0 else None
    if not m:
        return {"path": path, "error": "unreadable header"}
    p = {k: m.group(k) for k in ("run", "name", "crc", "pcrc")}
    for k in ("part", "of", "w", "h", "plen"):
        p[k] = int(m.group(k))
    payload = text[nl + 1 : nl + 1 + p["plen"]]
    p["path"] = path
    p["mtime"] = os.path.getmtime(path)
    if len(payload) != p["plen"]:
        p["error"] = "payload cut short (%d of %d chars)" % (len(payload), p["plen"])
    elif "%08x" % zlib.crc32(payload.encode("ascii")) != p["pcrc"]:
        p["error"] = "payload checksum mismatch"
    else:
        p["payload"] = payload
    return p


def lzw_decode(data):
    """data: bytes of 7-bit values, LSB-first bitstream of growing-width LZW codes."""
    out = bytearray()
    table = {}
    pos = acc = nacc = 0
    n = len(data)
    width, next_code, prev, pending = 9, FIRST, None, None
    while True:
        while nacc < width:
            if pos >= n:
                raise ValueError("ran out of data before the end code")
            acc |= data[pos] << nacc
            nacc += 7
            pos += 1
        code = acc & ((1 << width) - 1)
        acc >>= width
        nacc -= width
        if code == CLEAR:
            table = {}
            width, next_code, prev, pending = 9, FIRST, None, None
            continue
        if code == STOP:
            return bytes(out)
        if code < 256:
            entry = bytes((code,))
        elif code in table:
            entry = table[code]
        elif code == pending and prev is not None:
            entry = prev + prev[:1]
        else:
            raise ValueError("invalid code %d" % code)
        if prev is not None:
            table[pending] = prev + entry[:1]
        out += entry
        prev = entry
        pending = next_code
        if next_code < LIMIT:
            next_code += 1
        if next_code == (1 << width) and width < 16:
            width += 1


def unfilter(f, w):
    out = bytearray(f)
    row = w * 4
    for y in range(0, len(out), row):
        for i in range(y + 4, y + row):
            out[i] = (out[i] + out[i - 4]) & 255
    return bytes(out)


def write_png(path, w, h, rgba):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    stride = w * 4
    raw = b"".join(b"\x00" + rgba[y * stride : (y + 1) * stride] for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="folder to write the PNG files into")
    ap.add_argument("--run", help="export run id from SkyExportPrepare (default: the most recent run found)")
    ap.add_argument("paths", nargs="*", help="tool-results folders or files (default: ~/.claude/projects)")
    args = ap.parse_args()

    roots = args.paths or [os.path.join(os.path.expanduser("~"), ".claude", "projects")]
    files = []
    for r in roots:
        if os.path.isfile(r):
            files.append(r)
        else:
            files += glob.glob(os.path.join(r, "**", "*.txt"), recursive=True)

    pieces = [p for p in (read_piece(f) for f in files) if p]
    if not pieces:
        sys.exit("No export pieces found in: " + ", ".join(roots))
    run = args.run or max(pieces, key=lambda p: p.get("mtime", 0))["run"]
    pieces = [p for p in pieces if p.get("run") == run]
    print("run", run, "-", len(pieces), "piece file(s)")

    by_name = {}
    for p in pieces:
        by_name.setdefault(p["name"], []).append(p)

    os.makedirs(args.out, exist_ok=True)
    failed = 0
    for name in sorted(by_name):
        group = by_name[name]
        of, w, h, crc = group[0]["of"], group[0]["w"], group[0]["h"], group[0]["crc"]
        good = {}
        for p in group:
            if "payload" in p:
                good[p["part"]] = p["payload"]
        missing = [i for i in range(1, of + 1) if i not in good]
        if missing:
            failed += 1
            bad = ["part %d: %s (%s)" % (p["part"], p["error"], p["path"]) for p in group if "error" in p]
            print("%s: MISSING part(s) %s of %d -> re-request with shared.SkyExportPart" % (name, missing, of))
            for b in bad:
                print("   ", b)
            continue
        try:
            filtered = lzw_decode("".join(good[i] for i in range(1, of + 1)).encode("ascii"))
            if len(filtered) != w * h * 4:
                raise ValueError("decoded %d bytes, expected %d" % (len(filtered), w * h * 4))
            rgba = unfilter(filtered, w)
            if "%08x" % zlib.crc32(rgba) != crc:
                raise ValueError("pixel checksum mismatch")
        except ValueError as e:
            failed += 1
            print("%s: FAILED to decode: %s" % (name, e))
            continue
        path = os.path.join(args.out, re.sub(r"[^A-Za-z0-9_.-]", "_", name)[:80] + ".png")
        write_png(path, w, h, rgba)
        print("%s: saved %s (%dx%d, checksum ok)" % (name, path, w, h))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
