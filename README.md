# Uzebox core for Karabas Go / Mini / Mini G

Work in progress: a port of the [Uzebox](https://github.com/Uzebox/uzebox) retro game console (ATmega644 at
28.636 MHz) to the Karabas Go, Mini and Mini G boards (Xilinx Spartan-6 XC6SLX25).

Status: planning, see [docs/PLAN.md](docs/PLAN.md) (in Russian). [Русская версия](README.ru.md).

Clone with submodules: `git clone --recursive`, or `git submodule update --init` after a clone.

- `modules/` — shared Karabas Go board modules (karabas-go-modules).
- `upstream/uzebox/` — the original Uzebox sources (kernel, games, Uzem emulator, tools).
- `src/` — the core: `rtl/`, `sim/`, `tools/`.

License: GPL-3.0, as Uzebox.
