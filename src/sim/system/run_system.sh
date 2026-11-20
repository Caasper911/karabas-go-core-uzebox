#!/bin/bash
# Build (if needed) and run the system test bench (uzebox.v + SRAM model, video output checked).
# Usage: src/sim/system/run_system.sh <game.uze> [-n frames] [-p png_prefix] [-e every] [-k frame:frames:usb_key]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
B="$ROOT/src/sim/build/system"
mkdir -p "$B"
R="$ROOT/src/rtl"
MSYSTEM=UCRT64 /c/msys64/usr/bin/bash -lc "
cd '$B' &&
verilator --cc --exe --build -j 4 -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE \
  --flatten -DUZE_SIM_SDRAM --top-module uzebox -Mdir obj '$R/uzebox/uzebox.v' '$R/uzebox/uze_pm_sram.v' '$R/uzebox/uze_pads.v' \
  '$R/uzebox/uze_video.v' '$R/uzebox/uze_fb.v' '$R/uzebox/uze_spiram.v' '$R/sd/kg_sd_emu.v' '$ROOT/modules/rtl/mem/kg_tdpram.v' '$ROOT/modules/rtl/mcu/kg_bk_ram.v' '$ROOT/modules/rtl/mem/kg_sdpram.v' '$HERE/uze_wb_ram_sim.v' '$R/avr/atmega644.v' '$R/avr/avr_core.v' '$R/avr/avr_io_m644.v' \
  '$HERE/tb_system.cpp' -CFLAGS '-O2' -o tb_system.exe > build.log 2>&1 || { grep -i error build.log | head -20; exit 1; }"
GAME="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
cd "$B" && PATH="/c/msys64/ucrt64/bin:$PATH" ./obj/tb_system.exe "$GAME" "$@"
