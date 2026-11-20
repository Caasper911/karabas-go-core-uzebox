#!/usr/bin/env python3
"""Cut a byte range out of an Intel HEX file into a binary (unused bytes 0xFF, as an erased flash).
usage: hex2rom.py file.hex out.bin start end      (start / end: byte addresses, end exclusive)
Bootloader5: hex2rom.py Bootloader5.hex roms/uzeboot.bin 0xF000 0x10000"""
import sys
src, dst, start, end = sys.argv[1], sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0)
img = bytearray(b'\xff' * (end - start))
base = 0
for line in open(src):
    line = line.strip()
    if not line.startswith(':'):
        continue
    b = bytes.fromhex(line[1:])
    n, a, t = b[0], (b[1] << 8) | b[2], b[3]
    if t == 0:
        for i in range(n):
            x = base + a + i
            if start <= x < end:
                img[x - start] = b[4 + i]
    elif t == 2:
        base = ((b[4] << 8) | b[5]) << 4
    elif t == 4:
        base = ((b[4] << 8) | b[5]) << 16
open(dst, 'wb').write(img)
print("%s: %d bytes, %d used" % (dst, len(img), sum(1 for x in img if x != 0xFF)))
