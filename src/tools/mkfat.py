#!/usr/bin/env python3
"""mkfat.py - a FAT16 SD card image (no partition table, "superfloppy") with files in the root directory, for the
SD image of the Uzebox core (OSD SD card = Image) and the simulation of Bootloader5 / uzefs games.

usage: mkfat.py out.img [-s size_MB] file [file ...]
  files are stored under their 8.3 names (upper case), contiguous. Default size 32 MB (2 KB clusters).
karabas-go-core-uzebox, GPL-3.0-or-later.
"""
import os
import struct
import sys

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__); sys.exit(2)
    out = args.pop(0)
    size_mb = 32
    if args and args[0] == '-s':
        args.pop(0); size_mb = int(args.pop(0))
    files = args

    bps, spc = 512, 4                     # 2 KB clusters
    total = size_mb * 2048                # sectors
    reserved, nfats, root_entries = 1, 2, 512
    root_secs = root_entries * 32 // bps
    # FAT size: clusters = (total - reserved - root - 2 * fat) / spc, fat = (clusters + 2) * 2 / 512
    fat_secs = 1
    while True:
        clusters = (total - reserved - root_secs - nfats * fat_secs) // spc
        need = ((clusters + 2) * 2 + bps - 1) // bps
        if need <= fat_secs:
            break
        fat_secs = need
    assert 4085 <= clusters < 65525, "not a FAT16 size"
    data0 = reserved + nfats * fat_secs + root_secs

    img = bytearray(total * bps)
    bs = bytearray(512)
    bs[0:3] = b'\xEB\x3C\x90'
    bs[3:11] = b'KARABAS '
    struct.pack_into('<HBHBHHBHHHII', bs, 11, bps, spc, reserved, nfats, root_entries,
                     total if total < 65536 else 0, 0xF8, fat_secs, 63, 255, 0, total if total >= 65536 else 0)
    struct.pack_into('<BBBI11s8s', bs, 36, 0x80, 0, 0x29, 0x55AA1234, b'UZEBOX     ', b'FAT16   ')
    bs[510:512] = b'\x55\xAA'
    img[0:512] = bs

    fat = [0] * (clusters + 2)
    fat[0], fat[1] = 0xFFF8, 0xFFFF
    root = bytearray(root_secs * bps)
    nxt = 2
    for idx, path in enumerate(files):
        data = open(path, 'rb').read()
        base, ext = os.path.splitext(os.path.basename(path))
        name = (base.upper()[:8].ljust(8) + ext[1:].upper()[:3].ljust(3)).encode('ascii')
        ncl = max(1, (len(data) + spc * bps - 1) // (spc * bps))
        first = nxt
        for c in range(first, first + ncl):
            fat[c] = c + 1
        fat[first + ncl - 1] = 0xFFFF
        nxt += ncl
        off = (data0 + (first - 2) * spc) * bps
        img[off:off + len(data)] = data
        e = bytearray(32)
        e[0:11] = name
        e[11] = 0x20
        struct.pack_into('<HI', e, 26, first, len(data))
        struct.pack_into('<H', e, 20, 0)
        root[idx * 32:(idx + 1) * 32] = e
        print("%s: cluster %d, %d bytes" % (name.decode(), first, len(data)))
    fatb = bytearray(fat_secs * bps)
    for i, v in enumerate(fat):
        struct.pack_into('<H', fatb, i * 2, v)
    for n in range(nfats):
        o = (reserved + n * fat_secs) * bps
        img[o:o + len(fatb)] = fatb
    o = (reserved + nfats * fat_secs) * bps
    img[o:o + len(root)] = root
    open(out, 'wb').write(img)
    print("%s: %d MB, FAT16, %d clusters of %d bytes" % (out, size_mb, clusters, spc * bps))

main()
