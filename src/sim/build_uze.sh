#!/bin/bash
# Build the Uzebox tools (uzem, packrom, gconvert, ...) and games from upstream/uzebox in a copy
# (src/sim/build/uze), so the submodule stays clean. Needs msys2 ucrt64 with avr-gcc, SDL2, pkgconf.
# Usage: src/sim/build_uze.sh [demo ...]   (default: the test set below)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
UP="$HERE/../../upstream/uzebox"
B="$HERE/build/uze"
DEMOS="${*:-unittest Megatris SpriteDemo Arkanoid DonkeyKong Mode9Demo Mode5Demo Mode13ExtendedDemo SpaceInvaders PacMan ControllerTester MusicDemo}"
mkdir -p "$B"
for d in kernel tools Makefile; do [ -e "$B/$d" ] || cp -r "$UP/$d" "$B/"; done
mkdir -p "$B/demos"
for d in $DEMOS; do [ -e "$B/demos/$d" ] || cp -r "$UP/demos/$d" "$B/demos/"; done
MSYSTEM=UCRT64 /c/msys64/usr/bin/bash -lc "
cd '$B' && mkdir -p bin roms &&
for t in packrom gconvert mconvert dconvert uzem; do make -C tools/\$t OS=WIN32 DEST_DIR=\$(pwd)/bin/ >/dev/null || exit 1; done &&
for d in $DEMOS; do echo \"== \$d\"; make -C demos/\$d/default UZEBIN_DIR=\$(pwd)/bin/ 2>&1 | grep -E 'error|Error|uze' | head -5; done"
ls -la "$B"/demos/*/default/*.hex 2>/dev/null | awk '{print $5, $9}'
