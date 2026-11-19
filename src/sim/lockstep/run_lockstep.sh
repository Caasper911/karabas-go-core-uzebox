#!/bin/bash
# Build (if needed) and run the RTL-vs-Uzem lockstep test.
# Usage: src/sim/lockstep/run_lockstep.sh <game.hex|.uze> [tb options: -n frames -p png -e n -s n -q]
# Needs msys2 ucrt64: verilator, SDL2 (see docs/PLAN.md, Ф0).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../../.."
B="$ROOT/src/sim/build/lockstep"
U="$ROOT/upstream/uzebox/tools/uzem"
RTL="$ROOT/src/rtl/avr"
mkdir -p "$B"
MSYSTEM=UCRT64 /c/msys64/usr/bin/bash -lc "
cd '$B' &&
verilator --cc --exe --build -j 4 -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE \
  --flatten --top-module atmega644 -Mdir obj '$RTL/atmega644.v' '$RTL/avr_core.v' '$RTL/avr_io_m644.v' \
  '$HERE/tb_lockstep.cpp' '$U/avr8.cpp' '$U/uzerom.cpp' '$U/SDEmulator.cpp' \
  -CFLAGS '-O2 -DNOGDB=1 -DGUI=1 -D_GNU_SOURCE=1 -DJOY_ANALOG_DEADZONE=8192 -DSDL_MAIN_HANDLED -I$U -I$HERE \$(sdl2-config --cflags)' \
  -LDFLAGS '-lSDL2' -o tb_lockstep.exe > build.log 2>&1 || { tail -30 build.log; exit 1; }"
GAME="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
cd "$B" && PATH="/c/msys64/ucrt64/bin:$PATH" ./obj/tb_lockstep.exe "$GAME" "$@"
