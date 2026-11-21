# Ядро Uzebox для Karabas Go / Mini / Mini G

В работе: порт ретро-консоли [Uzebox](https://github.com/Uzebox/uzebox) (ATmega644 на 28.636 МГц) на платы
Karabas Go, Mini и Mini G (Xilinx Spartan-6 XC6SLX25).

Состояние: работает на Mini G, Mini и Go (720x480p 60 Гц или 720x576p 50 Гц из кадрового буфера, пункт OSD Video: HDMI, на Go — VGA; звук, пады SNES, USB-клавиатура как клавиатура Uzebox
или пад 1, USB-мышь как мышь SNES, ESP8266 на USART0 (Uzenet, ещё не проверен), SPI RAM (8 МБ или 128 КБ),
SD-карта или образ SD-карты (`.img` / `.bin`) с SD1 через файловый монтировщик MCU, Bootloader5, EEPROM в файле `.sav`).
Пока программа ждёт сектор образа SD, консоль стоит (картинка держится, звук на паузе): MCU отдаёт сектор
за несколько мс. См. [docs/PLAN.md](docs/PLAN.md). [English](README.md).

## Uzebox: сайты и программы

- [uzebox.org](https://uzebox.org/) — сайт консоли, её [вики](https://uzebox.org/wiki/Main_Page) и
  [форум](https://uzebox.org/forums/) (там объявляют новые игры и утилиты).
- Игры (`.uze`):
  - [Games and Demos](https://uzebox.org/wiki/Games_and_Demos) — текущий список, у каждой игры своя страница и
    ссылка на скачивание;
  - [Latest Rom List](https://uzebox.org/wiki/Latest_Rom_List) — один zip с играми, известными Uzebox Online Player;
  - [Games and Demos EX](https://uzebox.org/wiki/Games_and_Demos_EX) — старый список и Uzebox ROM Pack 1.0
    (`.hex` и `.uze`, устарел).
- Исходники: [Uzebox/uzebox](https://github.com/Uzebox/uzebox) на GitHub (kernel, демо и игры с исходниками,
  Bootloader5, утилиты `packrom` / `gconvert` / `mconvert`, схемы); [релизы](https://github.com/Uzebox/uzebox/releases)
  (сборки Uzem). В этом репозитории — в `upstream/uzebox`.
- Эмуляторы, чтобы попробовать игру на ПК: Uzem (в [Uzebox/uzebox](https://github.com/Uzebox/uzebox), `tools/uzem`),
  [CUzebox](https://github.com/Jubatian/cuzebox) ([страница в вики](https://uzebox.org/wiki/CUzebox)) и его
  ответвление с большей SPI RAM, ESP8266 и UART — [cuzebox-ex](https://github.com/weber21w/cuzebox-ex).

На плате: положите файлы `.uze` в `/uzebox` на SD-карте и выберите игру в OSD (Game) или включите в OSD
Bootloader5 и выберите игру в нём. Файлы, которые игра читает (данные, музыка, `.sav`), кладутся рядом с ней.
Поддерживаются образы SD-карты с SD1: в OSD выберите SD card = Image и образ (`.img` / `.bin`, FAT16 или FAT32)
в пункте SD image — программы видят его как свою SD-карту.

## Репозиторий

Клонировать с сабмодулями: `git clone --recursive` или `git submodule update --init` после клонирования.

- `modules/` — общие модули плат Karabas Go (karabas-go-modules).
- `upstream/uzebox/` — исходники Uzebox (ядро, игры, эмулятор Uzem, утилиты).
- `src/` — ядро: `rtl/`, `sim/`, `tools/`.

Лицензия: GPL-3.0, как у Uzebox.
