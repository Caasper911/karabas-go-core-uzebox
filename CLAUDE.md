# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A Uzebox core for the Karabas Go, Mini and Mini G boards (Xilinx Spartan-6 XC6SLX25, ISE 14.7, XST). Uzebox is an ATmega644 game console at 28.63636 MHz with no frame buffer: the games draw each line by cycle-counted writes to PORTC, so the AVR must be cycle-exact. No Uzebox on an FPGA existed when this started (2026-11-19). Docs, in Russian: `docs/PLAN.md` (facts, variants, decisions, phases). User decisions (2026-11-19, PLAN.md section 4): A = own cycle-exact ATmega644 core (uzem is the oracle, other AVR cores reference only), V1 = line doubler 1:1 per CPU cycle, 1440x480 at 57.27 MHz (2x CPU), M2 = 64 KB program flash in the external 2Mx16 SRAM (fallback M1 = BRAM), L1 = .uze loaded via the OSD (Bootloader5 later). Record a changed decision in PLAN.md.

## Layout

- `modules/`: submodule `karabas-go-modules` (kg_* board modules, MCU link v2, OSD, HDMI, audio).
- `upstream/uzebox/`: submodule of https://github.com/Uzebox/uzebox (GPL-3): kernel, demos (test corpus), `tools/uzem` (the reference emulator, oracle for the CPU / video / audio timing), `tools/packrom` (.uze format). Read only.
- `src/rtl/avr/`: `avr_core.v` (cycle-exact AVR CPU), `avr_io_m644.v` (ports, timer 1, watchdog, EEPROM, OCR2A sample, other registers read back), `atmega644.v` (core + IO + 4 KB SRAM BRAM; program memory outside, `pm_addr` registered, `pm_rdata` sampled at the end of the cycle).
- `src/sim/`: `build_uze.sh` builds uzem, the tools and the test games in a copy (`src/sim/build/uze`, needs msys2 ucrt64 avr-gcc + SDL2); `lockstep/` runs the RTL (Verilator) and Uzem's `avr8.cpp` in one program and compares the whole state after every instruction (`run_lockstep.sh <game.hex|.uze> -n frames -p png_prefix`, `run_suite.sh [frames]` for the game set, logs and last frames in `src/sim/build/suite`). The bench corrects the oracle where Uzem differs from the ATmega644 (EEPROM halt cycles); PLAN.md Ф0 lists the Uzem behaviours the RTL copies and the ones it does not. A change to the CPU / IO must keep `run_suite.sh` all OK.
- `src/rtl/uzebox/`: `uzebox.v` (the console without the board: atmega644, `uze_pm_sram.v` program memory in the board SRAM + .uze loader, `uze_pads.v` SNES pads from MCU joysticks / keyboard, `uze_video.v` finds the lines / frames of the game on PB0 (tolerant: old kernels have 1818-cycle lines) into a 4-line ring, `uze_fb.v` triple-buffered frame buffer in the SDRAM (`uze_sdram.v` from core-agon / core-doom) read out as CEA 720x480p 59.94 Hz at 27 MHz, `uze_spiram.v` SPI RAM in the SDRAM, `src/rtl/sd/kg_sd_emu.v` SD image on the file mounter, sound). SD image wait: while `kg_sd_emu` waits for the MCU (`waiting`), `sd_freeze` stops the whole ATmega (`freeze`: CPU, timer 1, watchdog, EEPROM, SPI) and `uze_video`, so no time passes for the game (timeout ~1.2 s). `src/rtl/karabas_minig_top.v`: the Mini G board (PLL 1 28.75 / 71.875 / 25 MHz, PLL 2 27 / 135 MHz, kg_mcu2, OSD, HDMI, PCM5102). Never make the output timing follow the game: monitors lose sync.
- Build: `make minig` in `src` (ISE 14.7 via the Windows block of the Makefile; Mini G only until Ф3), `make minig-report`; bump `build` in `src/core.json` with each change. `src/uzebox.kg` is committed, the `.bin` is not.
- `src/sim/system/run_system.sh <game.uze> -n frames -p png`: the whole console with an SRAM model and a wishbone RAM in place of the SDRAM controller (`UZE_SIM_SDRAM`), three clocks, the load through `LD_*`; each 720x480p output frame must equal one of the last game frames taken from PORTC / PB0 in Uzem's window. Run it after a change of `src/rtl/uzebox`.
- `src/synth/synth_core.sh`: XST + map + par of `atmega644` alone (LUTs, timing at 57.27 MHz).
- `src/tools/`: scripts. `docs/`: PLAN.md, images in `docs/img/`.

## Rules of the core

The rules of the other karabas-go cores apply: standard video timing with syncs always present, `FT_CLK_OUT` about 8 MHz on Mini / Mini G, Go `FDC_*` outputs 0 when unused, Mini / Mini G drive T3 (`FLASH_CS_N`) = 0, OSD switch index = item position unless `"index"`, an OSD value shows 10 characters at most, FL slots 0..7 only, Verilog-2001 for XST (`sv2v` for SV), imported code marked `karabas:`.

- Licence GPL-3.0 (as Uzebox); keep the notices of imported code.
- Never edit `upstream/`; changes go to `src/`.
- **Ask the user before every check on the board.** Ask before a firmware flash.
- One branch per phase of `docs/PLAN.md`, one PR at its end. Mini G only while working on one feature, all boards for a release.
- Keep README.md / README.ru.md / CLAUDE.md / docs/PLAN.md up to date with every change (docs in Russian, CLAUDE.md in English).

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a junction to `../karabas-go-notes` (private repo). Its `MEMORY.md` is split by repo; commit and push it after every memory change.
