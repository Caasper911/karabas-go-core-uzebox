# Uzebox core for Karabas Go / Mini / Mini G

Work in progress: a port of the [Uzebox](https://github.com/Uzebox/uzebox) retro game console (ATmega644 at
28.636 MHz) to the Karabas Go, Mini and Mini G boards (Xilinx Spartan-6 XC6SLX25).

Status: playable on Mini G (720x480p HDMI from a frame buffer, sound, SNES pads / keyboard, SPI RAM, SD card
or an SD image through the file mounter of the MCU, Bootloader5, EEPROM saved to a `.sav` file); Go and Mini
next. While a program waits for a sector of the SD image, the console is frozen (picture held, sound paused), as
the MCU serves a sector in a few ms. See [docs/PLAN.md](docs/PLAN.md) (in Russian). [Русская версия](README.ru.md).

Clone with submodules: `git clone --recursive`, or `git submodule update --init` after a clone.

- `modules/` — shared Karabas Go board modules (karabas-go-modules).
- `upstream/uzebox/` — the original Uzebox sources (kernel, games, Uzem emulator, tools).
- `src/` — the core: `rtl/`, `sim/`, `tools/`.

License: GPL-3.0, as Uzebox.
