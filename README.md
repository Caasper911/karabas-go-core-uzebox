# Uzebox core for Karabas Go / Mini / Mini G

Work in progress: a port of the [Uzebox](https://github.com/Uzebox/uzebox) retro game console (ATmega644 at
28.636 MHz) to the Karabas Go, Mini and Mini G boards (Xilinx Spartan-6 XC6SLX25).

Status: works on Mini G, Mini and Go (720x480p from a frame buffer: HDMI, VGA on Go; sound, SNES pads, the USB keyboard as the Uzebox keyboard or as
pad 1, the USB mouse as the SNES mouse, the ESP8266 on USART0 (Uzenet, not checked yet), SPI RAM (8 MB or 128 KB), SD card
or an SD card image (`.img` / `.bin`) from SD1 through the file mounter of the MCU, Bootloader5, EEPROM saved to a `.sav` file). While a program waits for a sector of the SD image, the console is frozen (picture held, sound paused), as
the MCU serves a sector in a few ms. See [docs/PLAN.md](docs/PLAN.md) (in Russian). [Русская версия](README.ru.md).

## Uzebox: sites and software

- [uzebox.org](https://uzebox.org/): the home of the console, its [wiki](https://uzebox.org/wiki/Main_Page) and
  [forums](https://uzebox.org/forums/) (new games and tools are announced there).
- Games (`.uze`):
  - [Games and Demos](https://uzebox.org/wiki/Games_and_Demos): the current list, each game with its page and download;
  - [Latest Rom List](https://uzebox.org/wiki/Latest_Rom_List): one zip with the games known to the Uzebox Online Player;
  - [Games and Demos EX](https://uzebox.org/wiki/Games_and_Demos_EX): the older list with the Uzebox ROM Pack 1.0
    (`.hex` and `.uze`, outdated).
- Sources: [Uzebox/uzebox](https://github.com/Uzebox/uzebox) on GitHub (the kernel, the demos and games with
  their sources, Bootloader5, the tools `packrom` / `gconvert` / `mconvert`, the schematics);
  [releases](https://github.com/Uzebox/uzebox/releases) (Uzem builds). This repository has it in `upstream/uzebox`.
- Emulators to try a game on a PC: Uzem (in [Uzebox/uzebox](https://github.com/Uzebox/uzebox), `tools/uzem`),
  [CUzebox](https://github.com/Jubatian/cuzebox) ([wiki page](https://uzebox.org/wiki/CUzebox)) and its fork with
  more SPI RAM, the ESP8266 and the UART, [cuzebox-ex](https://github.com/weber21w/cuzebox-ex).

On the board: put the `.uze` files in `/uzebox` on the SD card and pick one in the OSD (Game), or turn on
Bootloader5 in the OSD and choose the game in it. The files a game reads (data, music, `.sav`) go next to it.
SD card images are supported from SD1: set SD card = Image in the OSD and pick the image (`.img` / `.bin`, FAT16
or FAT32) in SD image; the programs then see it as their SD card.

## Repository

Clone with submodules: `git clone --recursive`, or `git submodule update --init` after a clone.

- `modules/` — shared Karabas Go board modules (karabas-go-modules).
- `upstream/uzebox/` — the original Uzebox sources (kernel, games, Uzem emulator, tools).
- `src/` — the core: `rtl/`, `sim/`, `tools/`.

License: GPL-3.0, as Uzebox.
