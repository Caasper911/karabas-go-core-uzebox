// tb_lockstep.cpp - runs the RTL ATmega644 (Verilator) and Uzem's avr8 (the oracle) instruction by
// instruction and compares the whole visible state after every instruction: PC, cycles, registers,
// SREG, SP, the pixel, the IO registers; the SRAM every 4096 instructions. Saves RTL frames as PNG.
// karabas-go-core-uzebox, GPL-3.0-or-later.
//
// Usage: tb_lockstep <game.hex|game.uze> [-n frames] [-p png_prefix] [-e every_n_frames] [-s skip_frames]
//        [-q] (no lockstep: RTL only, fast)

#define SDL_MAIN_HANDLED
#include "avr8_open.h"
#include "uzerom.h"
#include "Vatmega644.h"
#include "Vatmega644___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>

double sc_time_stamp() { return 0; }
// Uzem seeds its watchdog with rand(): make it deterministic (the RTL watchdog restarts at 0).
extern "C" int rand(void) { return 0; }

// ------------------------------------------------------------------ PNG (stored deflate)
static uint32_t crc_table[256];
static void crc_init() {
	for (uint32_t n = 0; n < 256; n++) {
		uint32_t c = n;
		for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		crc_table[n] = c;
	}
}
static uint32_t crc(const uint8_t *b, size_t n, uint32_t c = 0xFFFFFFFFu) {
	for (size_t i = 0; i < n; i++) c = crc_table[(c ^ b[i]) & 0xFF] ^ (c >> 8);
	return c;
}
static void be32(std::vector<uint8_t> &v, uint32_t x) {
	v.push_back(x >> 24); v.push_back(x >> 16); v.push_back(x >> 8); v.push_back(x);
}
static void chunk(FILE *f, const char *t, const std::vector<uint8_t> &d) {
	std::vector<uint8_t> b; be32(b, d.size());
	b.insert(b.end(), t, t + 4); b.insert(b.end(), d.begin(), d.end());
	uint32_t c = crc(b.data() + 4, b.size() - 4) ^ 0xFFFFFFFFu;
	be32(b, c); fwrite(b.data(), 1, b.size(), f);
}
static void write_png(const char *name, const uint8_t *rgb, int w, int h) {
	FILE *f = fopen(name, "wb");
	if (!f) return;
	static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
	fwrite(sig, 1, 8, f);
	std::vector<uint8_t> hdr; be32(hdr, w); be32(hdr, h);
	hdr.push_back(8); hdr.push_back(2); hdr.push_back(0); hdr.push_back(0); hdr.push_back(0);
	chunk(f, "IHDR", hdr);
	std::vector<uint8_t> raw;
	for (int y = 0; y < h; y++) { raw.push_back(0); raw.insert(raw.end(), rgb + y * w * 3, rgb + (y + 1) * w * 3); }
	std::vector<uint8_t> z; z.push_back(0x78); z.push_back(0x01);
	size_t pos = 0;
	while (pos < raw.size()) {
		size_t n = raw.size() - pos; if (n > 65535) n = 65535;
		z.push_back(pos + n == raw.size()); z.push_back(n & 0xFF); z.push_back(n >> 8);
		z.push_back(~n & 0xFF); z.push_back((~n >> 8) & 0xFF);
		z.insert(z.end(), raw.begin() + pos, raw.begin() + pos + n); pos += n;
	}
	uint32_t a = 1, b = 0;
	for (uint8_t c : raw) { a = (a + c) % 65521; b = (b + a) % 65521; }
	be32(z, (b << 16) | a);
	chunk(f, "IDAT", z);
	chunk(f, "IEND", std::vector<uint8_t>());
	fclose(f);
}

// ------------------------------------------------------------------ RTL
static Vatmega644 *top;
static uint16_t pm[32768];
static uint64_t rtl_cycle = 0;

// frame capture, the same window as Uzem: line = rising edge of PB0, 720 pixels from +168 cycles
// (every second cycle), lines 38.. after the half-period lines of the vertical sync, 224 lines.
static uint8_t linebuf[2048];
static uint8_t frame[720 * 224 * 3];
static int scanline = -999;
static uint64_t prev_rise = 0, line_start = 0;
static int prev_pb0 = 0;
static int frames = 0;
static std::string png_prefix;
static int png_every = 0, png_skip = 0;

static void video_tick() {
	linebuf[rtl_cycle & 0x7FF] = top->pixel;
	int pb0 = top->portb & 1;
	if (pb0 && !prev_pb0) {
		uint64_t el = rtl_cycle - prev_rise;
		if (scanline == -999 && el >= 900 && el <= 920) scanline = -38;
		else if (scanline != -999) {
			if (scanline >= 0 && scanline < 224) {
				for (int i = 0; i < 720; i++) {
					uint8_t p = linebuf[(line_start + 168 + 2 * i) & 0x7FF];
					uint8_t *o = &frame[(scanline * 720 + i) * 3];
					o[0] = ((p & 7) * 255) / 7; o[1] = (((p >> 3) & 7) * 255) / 7; o[2] = (((p >> 6) & 3) * 255) / 3;
				}
			}
			scanline++;
			line_start = rtl_cycle;
			if (scanline == 224) {
				frames++;
				if (!png_prefix.empty() && frames > png_skip && png_every && (frames % png_every) == 0) {
					char n[512]; snprintf(n, sizeof n, "%s_%04d.png", png_prefix.c_str(), frames);
					write_png(n, frame, 720, 224);
				}
				scanline = -999;
			}
		}
		prev_rise = rtl_cycle;
	}
	prev_pb0 = pb0;
}

static void tick() {
	top->clk = 1; top->eval();
	rtl_cycle++;
	top->clk = 0; top->eval();
	top->pm_rdata = pm[top->pm_addr];
	top->eval();
	video_tick();
}

// ------------------------------------------------------------------ main
static avr8 *u;

// Uzem adds 4 cycles for an EEPROM access without running the timers; the ATmega644 halts the CPU
// (read 4 cycles, write 2) while the timers run. Returns the halt cycles of the instruction at pc.
static int eeprom_halt(uint16_t pc) {
	uint16_t w = u->progmem[pc & 0x7FFF], w2 = u->progmem[(pc + 1) & 0x7FFF];
	int v = -1;
	if ((w & 0xFF00) == 0x9A00 && ((w >> 3) & 31) == 0x1F) v = u->EECR | (1 << (w & 7));        // SBI EECR
	else if ((w & 0xF800) == 0xB800 && ((((w >> 5) & 0x30) | (w & 0xF)) == 0x1F)) v = u->r[(w >> 4) & 31];  // OUT
	else if ((w & 0xFE0F) == 0x9200 && w2 == 0x3F) v = u->r[(w >> 4) & 31];                       // STS
	if (v < 0) return 0;
	if (v & 1) return 4;
	if ((v & 2) && (u->EECR & 4)) return 2;
	return 0;
}
static bool lockstep = true;

static uint8_t rtl_reg(int i) {
	return (top->rootp->atmega644__DOT__cpu__DOT__rf[i / 4] >> ((i % 4) * 8)) & 0xFF;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	crc_init();
	if (argc < 2) { fprintf(stderr, "usage: %s game.hex|game.uze [-n frames] [-p png] [-e n] [-s n] [-q]\n", argv[0]); return 2; }
	const char *game = argv[1];
	int max_frames = 30;
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "-n") && i + 1 < argc) max_frames = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-p") && i + 1 < argc) png_prefix = argv[++i];
		else if (!strcmp(argv[i], "-e") && i + 1 < argc) png_every = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-s") && i + 1 < argc) png_skip = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-q")) lockstep = false;
	}
	if (!png_prefix.empty() && !png_every) png_every = 1;

	u = new avr8();
	memset(u->progmem, 0, sizeof(u->progmem));
	unsigned char *buf = (unsigned char *)u->progmem;
	size_t len = strlen(game);
	bool ok;
	if (len > 4 && !strcasecmp(game + len - 4, ".uze")) {
		RomHeader h;
		ok = loadUzeImage((char *)game, &h, buf);
	} else {
		unsigned int n = 0;
		ok = loadHex(game, buf, &n);
	}
	if (!ok) { fprintf(stderr, "cannot load %s\n", game); return 2; }
	memcpy(pm, u->progmem, sizeof(pm));
	u->decodeFlash();
	if (lockstep) {
		SDL_setenv("SDL_VIDEODRIVER", "dummy", 1);
		SDL_setenv("SDL_AUDIODRIVER", "dummy", 1);
		u->enableSound = false;
		if (!u->init_gui()) { fprintf(stderr, "uzem init_gui failed\n"); return 2; }
	}

	top = new Vatmega644;
	top->pina = 0xFF; top->pinb = 0; top->pinc = 0; top->pind = 0;
	top->rst = 1; top->clk = 0; top->eval();
	tick(); tick();
	top->rst = 0; top->eval();
	while (!top->insn_start) tick();

	uint64_t steps = 0, last_start = rtl_cycle;
	uint32_t ring[16]; int rp = 0;
	// PINx: inputs; PORTB / PORTC / OCR2A: Uzem does not store them; the rest: compared above (own registers)
	const int io_skip[] = {0x00, 0x03, 0x05, 0x06, 0x08, 0x09, 0x0B, 0x16, 0x1F, 0x20, 0x3D, 0x3E, 0x3F, 0x40, 0x64, 0x65, 0x93};
	while (frames < max_frames) {
		uint32_t upc = u ? u->pc : 0;
		ring[rp++ & 15] = upc;
		unsigned int ucy = 0;
		if (lockstep) {
			int eh = eeprom_halt(u->pc);
			ucy = u->exec();
			if (eh) {                        // replace Uzem's 4 frozen cycles by eh running ones
				u->cycleCounter -= 4; ucy -= 4;
				for (int i = 0; i < eh; i++) u->update_hardware();
				ucy += eh;
			}
			top->pina = u->PINA;
		}
		do tick(); while (!top->insn_start);
		unsigned int rcy = rtl_cycle - last_start;
		last_start = rtl_cycle;
		steps++;
		if (!lockstep) continue;

		char why[256] = "";
		if (top->dbg_pc != u->pc) snprintf(why, sizeof why, "pc rtl %04x uzem %04x", top->dbg_pc, u->pc);
		else if (rcy != ucy) snprintf(why, sizeof why, "cycles rtl %u uzem %u", rcy, ucy);
		else {
			for (int i = 0; i < 32 && !why[0]; i++)
				if (rtl_reg(i) != u->r[i]) snprintf(why, sizeof why, "r%d rtl %02x uzem %02x", i, rtl_reg(i), u->r[i]);
			auto *R = top->rootp;
			uint16_t usp = u->SPL | (u->SPH << 8);
			unsigned ut1 = (u->TCNT1 + u->timer1_base - u->timer1_next) & 0xFFFF;
			if (why[0]) ;
			else if (R->atmega644__DOT__cpu__DOT__sreg != u->SREG) snprintf(why, sizeof why, "SREG rtl %02x uzem %02x", R->atmega644__DOT__cpu__DOT__sreg, u->SREG);
			else if (R->atmega644__DOT__cpu__DOT__sp != usp) snprintf(why, sizeof why, "SP rtl %04x uzem %04x", R->atmega644__DOT__cpu__DOT__sp, usp);
			else if (top->pixel != u->pixel_raw) snprintf(why, sizeof why, "pixel rtl %02x uzem %02x", top->pixel, u->pixel_raw);
			else if (R->atmega644__DOT__io__DOT__tcnt1 != ut1) snprintf(why, sizeof why, "TCNT1 rtl %04x uzem %04x", R->atmega644__DOT__io__DOT__tcnt1, ut1);
			else if (R->atmega644__DOT__io__DOT__tifr1 != u->TIFR1) snprintf(why, sizeof why, "TIFR1 rtl %02x uzem %02x", R->atmega644__DOT__io__DOT__tifr1, u->TIFR1);
			else if (R->atmega644__DOT__io__DOT__wdtcsr != u->WDTCSR) snprintf(why, sizeof why, "WDTCSR rtl %02x uzem %02x", R->atmega644__DOT__io__DOT__wdtcsr, u->WDTCSR);
			else if (top->porta != u->PORTA) snprintf(why, sizeof why, "PORTA rtl %02x uzem %02x", top->porta, u->PORTA);
			else if (top->portd != u->PORTD) snprintf(why, sizeof why, "PORTD rtl %02x uzem %02x", top->portd, u->PORTD);
			else {
				for (int a = 0; a < 0xE0 && !why[0]; a++) {
					bool skip = false;
					for (int s : io_skip) if (s == a) skip = true;
					if (skip) continue;
					uint8_t g = R->atmega644__DOT__io__DOT__gen[a];
					if (g != u->io[a]) snprintf(why, sizeof why, "io[%02x] rtl %02x uzem %02x", a, g, u->io[a]);
				}
			}
			if (!why[0] && (steps & 4095) == 0) {
				for (int a = 0; a < 4096 && !why[0]; a++) {
					uint8_t s = R->atmega644__DOT__sram[a];
					if (s != u->sram[a]) snprintf(why, sizeof why, "sram[%03x] rtl %02x uzem %02x", a + 0x100, s, u->sram[a]);
				}
			}
		}
		if (why[0]) {
			printf("MISMATCH after step %llu (cycle %llu, frame %d): %s\n", (unsigned long long)steps,
			       (unsigned long long)rtl_cycle, frames, why);
			printf("last instructions (uzem pc, oldest first):");
			for (int i = 0; i < 16; i++) printf(" %04x", ring[(rp + i) & 15]);
			printf("\ninstruction at %04x: %04x %04x\n", upc, pm[upc & 0x7FFF], pm[(upc + 1) & 0x7FFF]);
			auto *R = top->rootp;
			printf("rtl : TCNT1 %04x TIFR1 %02x TIMSK1 %02x TCCR1B %02x OCR1A %04x OCR1B %04x SREG %02x WDTCSR %02x\n",
			       R->atmega644__DOT__io__DOT__tcnt1, R->atmega644__DOT__io__DOT__tifr1, R->atmega644__DOT__io__DOT__timsk1,
			       R->atmega644__DOT__io__DOT__tccr1b, R->atmega644__DOT__io__DOT__ocr1a, R->atmega644__DOT__io__DOT__ocr1b,
			       R->atmega644__DOT__cpu__DOT__sreg, R->atmega644__DOT__io__DOT__wdtcsr);
			printf("uzem: TCNT1 %04x TIFR1 %02x TIMSK1 %02x TCCR1B %02x OCR1A %04x OCR1B %04x SREG %02x WDTCSR %02x\n",
			       (u->TCNT1 + u->timer1_base - u->timer1_next) & 0xFFFF, u->TIFR1, u->TIMSK1, u->TCCR1B,
			       u->OCR1AL | (u->OCR1AH << 8), u->OCR1BL | (u->OCR1BH << 8), u->SREG, u->WDTCSR);
			return 1;
		}
	}
	printf("OK: %llu instructions, %llu cycles, %d frames%s\n", (unsigned long long)steps,
	       (unsigned long long)rtl_cycle, frames, lockstep ? ", RTL == Uzem" : " (RTL only)");
	return 0;
}
