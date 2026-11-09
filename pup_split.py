#!/usr/bin/env python3
"""Teilt den SLB2-Container in die Fragmente, ohne zu entschluesseln."""
import sys, os, hashlib

HDR, REC = 0x20, 0x30


def main(argv):
    if len(argv) != 3:
        print("usage: pup_split.py <PS4UPDATE.PUP> <outdir>")
        return 2
    src, outdir = argv[1], argv[2]
    blob = open(src, "rb").read()
    if blob[:4] != b"SLB2":
        print("kein SLB2-Container")
        return 1

    magic = blob[0:4].decode()
    version = int.from_bytes(blob[0x04:0x08], "little")
    flags = int.from_bytes(blob[0x08:0x0C], "little")
    count = int.from_bytes(blob[0x0C:0x10], "little")
    sectors = int.from_bytes(blob[0x10:0x14], "little")
    print("magic %s version %d flags 0x%X eintraege %d sektoren %d (0x%X bytes)"
          % (magic, version, flags, count, sectors, sectors * 512))

    os.makedirs(outdir, exist_ok=True)
    spans = []
    for i in range(count):
        r = blob[HDR + i * REC: HDR + (i + 1) * REC]
        off = int.from_bytes(r[0x00:0x04], "little") * 512
        ln = int.from_bytes(r[0x04:0x08], "little")
        name = r[0x10:0x30].split(b"\0")[0].decode("latin1") or "eintrag%d" % i
        if off + ln > len(blob):
            print("[%d] %s laeuft ueber das dateiende (0x%X+%d)" % (i, name, off, ln))
        spans.append((off, off + ln, name))

    spans.sort()
    for a, b in zip(spans, spans[1:]):
        if a[1] > b[0]:
            print("ueberlappung: %s und %s" % (a[2], b[2]))

    for i, (off, end, name) in enumerate(spans):
        data = blob[off:end]
        open(os.path.join(outdir, name), "wb").write(data)
        fh = data[0:0x10]
        hs = int.from_bytes(fh[0x0C:0x0E], "little") + int.from_bytes(fh[0x0E:0x10], "little")
        print("[%d] %s 0x%X..0x%X %d bytes sha256 %s"
              % (i, name, off, end, len(data), hashlib.sha256(data).hexdigest()[:16]))
        print("    magic %s version %d mode %d endian %d flags 0x%X content %d header 0x%X"
              % (fh[0:4].hex(), fh[4], fh[5], fh[6], fh[7], fh[8], hs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
