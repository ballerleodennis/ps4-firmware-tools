#!/usr/bin/env python3
"""Known-plaintext auf u64 file_size, dann Segmenttabelle."""
import sys
from Crypto.Cipher import AES

BASE, REC = 0x20, 0x30
KEYS = [bytes.fromhex(x) for x in (
    "46334a6e6d31616e6867573030366279",
    "2c5f2d6c393930366477736666623332",
    "63343961653463373031323662666564")]


def main(argv):
    blob = open(argv[1], "rb").read()
    count = int.from_bytes(blob[0x0C:0x10], "little")
    entries = []
    for i in range(count):
        r = blob[BASE + i * REC: BASE + (i + 1) * REC]
        entries.append((int.from_bytes(r[0:4], "little") * 512,
                        int.from_bytes(r[4:12], "little"),
                        r[0x10:0x20].split(b"\0")[0].decode("latin1")))

    frag, flen, _ = entries[0]
    hsize = int.from_bytes(blob[frag + 0x0C:frag + 0x0E], "little") + \
            int.from_bytes(blob[frag + 0x0E:frag + 0x10], "little")
    exp = flen.to_bytes(8, "little")
    print("erwarteter block 0x10: %s | header_size 0x%X" % (exp.hex(), hsize))

    win = None
    for ki, k in enumerate(KEYS):
        b = AES.new(k, AES.MODE_ECB).decrypt(blob[frag + 0x10:frag + 0x20])
        ok = b[0:8] == exp
        print("  key %d: %s %s" % (ki + 1, b.hex(), "TREFFER" if ok else ""))
        if ok:
            win = k
    if win is None:
        print("kein schluessel passt")
        return 0

    for mode in ("ecb", "cbc"):
        c = AES.new(win, AES.MODE_ECB) if mode == "ecb" else AES.new(win, AES.MODE_CBC, b"\0" * 16)
        h = c.decrypt(blob[frag + 0x10:frag + 0x10 + hsize - 0x10])
        segs = int.from_bytes(h[0x08:0x0A], "little")
        print("--- %s: segmente=%d unknown_1A=0x%X" % (mode, segs, int.from_bytes(h[0x0A:0x0C], "little")))
        for i in range(min(segs, 6)):
            o = i * 0x20
            print("  [%d] flags=%08X off=0x%X csize=%d usize=%d"
                  % (i, int.from_bytes(h[o:o + 4], "little"),
                     int.from_bytes(h[o + 8:o + 0x10], "little"),
                     int.from_bytes(h[o + 0x10:o + 0x18], "little"),
                     int.from_bytes(h[o + 0x18:o + 0x20], "little")))
        print("  metadaten ab 0x%X:" % (0x20 + segs * 0x20))
        m = 0x20 + segs * 0x20
        for o in range(m, min(m + 0x80, len(h)), 16):
            print("    +0x%03X: %s" % (o, " ".join("%02X" % x for x in h[o:o + 16])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
