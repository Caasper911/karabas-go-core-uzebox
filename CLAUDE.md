# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A Uzebox core for the Karabas Go, Mini and Mini G boards (Xilinx Spartan-6 XC6SLX25, ISE 14.7, XST). Uzebox is an ATmega644 game console at 28.63636 MHz with no frame buffer: the games draw each line by cycle-counted writes to PORTC, so the AVR must be cycle-exact. No Uzebox on an FPGA existed when this started (2026-11-19). Docs, in Russian: `docs/PLAN.md` (facts, variants, decisions, phases). The variants of PLAN.md section 3 wait for the user's choice; record the choice in its section 4 and follow the phases.

## Layout

- `modules/`: submodule `karabas-go-modules` (kg_* board modules, MCU link v2, OSD, HDMI, audio).
- `upstream/uzebox/`: submodule of https://github.com/Uzebox/uzebox (GPL-3): kernel, demos (test corpus), `tools/uzem` (the reference emulator, oracle for the CPU / video / audio timing), `tools/packrom` (.uze format). Read only.
- `src/rtl/`: our RTL (AVR core, peripherals, tops). `src/sim/`: testbenches (Verilator / ISim). `src/tools/`: scripts (.uze/.hex conversion, trace compare, top generation).
- `docs/`: PLAN.md, images in `docs/img/`.

## Rules of the core

The rules of the other karabas-go cores apply: standard video timing with syncs always present, `FT_CLK_OUT` about 8 MHz on Mini / Mini G, Go `FDC_*` outputs 0 when unused, Mini / Mini G drive T3 (`FLASH_CS_N`) = 0, OSD switch index = item position unless `"index"`, an OSD value shows 10 characters at most, FL slots 0..7 only, Verilog-2001 for XST (`sv2v` for SV), imported code marked `karabas:`.

- Licence GPL-3.0 (as Uzebox); keep the notices of imported code.
- Never edit `upstream/`; changes go to `src/`.
- **Ask the user before every check on the board.** Ask before a firmware flash.
- One branch per phase of `docs/PLAN.md`, one PR at its end. Mini G only while working on one feature, all boards for a release.
- Keep README.md / README.ru.md / CLAUDE.md / docs/PLAN.md up to date with every change (docs in Russian, CLAUDE.md in English).

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a junction to `../karabas-go-notes` (private repo). Its `MEMORY.md` is split by repo; commit and push it after every memory change.
