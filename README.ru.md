# Ядро Uzebox для Karabas Go / Mini / Mini G

В работе: порт ретро-консоли [Uzebox](https://github.com/Uzebox/uzebox) (ATmega644 на 28.636 МГц) на платы
Karabas Go, Mini и Mini G (Xilinx Spartan-6 XC6SLX25).

Состояние: играбельно на Mini G (720x480p по HDMI из кадрового буфера, звук, пады SNES, USB-клавиатура как клавиатура Uzebox
или пад 1, USB-мышь как мышь SNES, ESP8266 на USART0 (Uzenet), SPI RAM,
SD-карта или образ SD через файловый монтировщик MCU, Bootloader5, EEPROM в файле `.sav`); дальше Go и Mini.
Пока программа ждёт сектор образа SD, консоль стоит (картинка держится, звук на паузе): MCU отдаёт сектор
за несколько мс. См. [docs/PLAN.md](docs/PLAN.md). [English](README.md).

Клонировать с сабмодулями: `git clone --recursive` или `git submodule update --init` после клонирования.

- `modules/` — общие модули плат Karabas Go (karabas-go-modules).
- `upstream/uzebox/` — исходники Uzebox (ядро, игры, эмулятор Uzem, утилиты).
- `src/` — ядро: `rtl/`, `sim/`, `tools/`.

Лицензия: GPL-3.0, как у Uzebox.
