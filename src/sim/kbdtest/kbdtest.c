/*
 * kbdtest - a test of the Uzebox keyboard (kernel keyboard.c, the adapter in pad port 2) and of USART0 (the
 * ESP8266 of Uzenet) for the Karabas Go core.
 *
 * Row 2..: the typed keys (KeyboardPoll, shifted). Each key also goes out on the UART (115200, U2X).
 * Row 12..: the bytes that came in on the UART. Row 24: pad 1 (ReadJoypad, hex); row 25: the key count.
 * F1 sends "AT\r\n" (an ESP answers "OK").
 *
 * karabas-go-core-uzebox, GPL-3.0-or-later.
 */

#include <stdbool.h>
#include <avr/io.h>
#include <stdlib.h>
#include <avr/pgmspace.h>
#include <uzebox.h>
#include <keyboard.h>

#include "../tutorial/data/font-6x8-full.inc"

static u8 kx = 1, ky = 2, ux = 1, uy = 12;
static u16 keys = 0, rx = 0;

static void put(u8 *x, u8 *y, u8 top, u8 bottom, u8 c)
{
	if (c == '\r') return;
	if (c == '\n' || c == KB_ENTER || *x >= SCREEN_TILES_H - 1) {
		*x = 1;
		if (++*y > bottom) *y = top;
		for (u8 i = 1; i < SCREEN_TILES_H - 1; i++) PrintChar(i, *y, ' ');
		if (c == '\n' || c == KB_ENTER) return;
	}
	if (c < 32 || c > 126) c = '?';
	PrintChar((*x)++, *y, c);
}

static void send(const char *s)
{
	while (*s) UartSendChar(*s++);
}

int main()
{
	SetFontTable(font);
	ClearVram();
	Print(1, 0, PSTR("KEYBOARD + UART TEST"));
	Print(1, 11, PSTR("UART IN:"));
	Print(1, 23, PSTR("PAD 1:"));

	UBRR0H = 0;
	UBRR0L = 30;                     // 115200 with U2X
	UCSR0A = (1 << U2X0);
	UCSR0C = (1 << UCSZ01) | (1 << UCSZ00);
	UCSR0B = (1 << RXEN0) | (1 << TXEN0);

	while (1) {
		WaitVsync(1);
		KeyboardPoll();
		if (KeyboardHasKey()) {
			u8 k = KeyboardGetKey(true);
			keys++;
			if (k == KB_F1) send("AT\r\n");
			else {
				put(&kx, &ky, 2, 9, k);
				UartSendChar(k == KB_ENTER ? '\r' : k);
				if (k == KB_ENTER) UartSendChar('\n');
			}
		}
		s16 c;
		while ((c = UartReadChar()) >= 0) {
			rx++;
			put(&ux, &uy, 12, 21, (u8)c);
		}
		PrintHexInt(8, 23, ReadJoypad(0));
		Print(1, 25, PSTR("KEYS"));
		PrintInt(10, 25, keys, true);
		Print(13, 25, PSTR("RX"));
		PrintInt(20, 25, rx, true);
	}
}
