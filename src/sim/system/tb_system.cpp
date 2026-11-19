// tb_system.cpp - the whole console (uzebox.v) with a model of the async board SRAM: loads a .uze through
// the LD_* loader ports (as kg_mcu2 does: a byte every 8 CPU clocks), runs it and checks the video
// output (720 x 480 window, the doubled picture: pixel x = cycle 168 + 2x) against a reference frame taken from PORTC / PB0 the
// way Uzem does (picture x = cycle 168 + x after the rise of PB0, rows from the 38th line after the
// first half line). Saves output frames as PNG. Also finds V_FIRST (the input line of picture row 0).
// karabas-go-core-uzebox, GPL-3.0-or-later.
//
// Usage: tb_system <game.uze> [-n frames] [-p png_prefix] [-e every] [-k start_frame:frames:usb_key]

#include "Vuzebox.h"
#include "Vuzebox___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include "../lockstep/png.h"

double sc_time_stamp() { return 0; }

static Vuzebox *top;
static uint16_t sram[1 << 21];
static uint64_t cyc = 0;

static void sram_eval() {
	uint32_t a = top->sram_a & 0x1FFFFF;
	if (top->sram_dq_oe) {
		if (!(top->sram_we_n & 1)) sram[a] = (sram[a] & 0xFF00) | (top->sram_dq_o & 0x00FF);
		if (!(top->sram_we_n & 2)) sram[a] = (sram[a] & 0x00FF) | (top->sram_dq_o & 0xFF00);
	}
	top->sram_dq_i = (top->sram_oe_n == 0) ? sram[a] : 0xFFFF;
}

// reference: Uzem's window on PORTC / PB0
static uint8_t linebuf[2048];
static std::vector<uint8_t> ref(1440 * 224), ref_prev(1440 * 224);
static int scanline = -999, ref_frames = 0, vfirst_seen = -1;
static uint64_t prev_rise = 0, line_start = 0;
static int prev_pb0 = 0;
static void ref_tick() {
	auto *R = top->rootp;
	linebuf[cyc & 0x7FF] = R->uzebox__DOT__pixel;
	int pb0 = R->uzebox__DOT__portb & 1;
	if (pb0 && !prev_pb0) {
		uint64_t el = cyc - prev_rise;
		if (scanline == -999 && el >= 900 && el <= 920) scanline = -38;
		else if (scanline != -999) {
			if (scanline >= 0 && scanline < 224)
				for (int i = 0; i < 1440; i++) ref[scanline * 1440 + i] = linebuf[(line_start + 168 + i) & 0x7FF];
			scanline++;
			line_start = cyc;
			if (scanline == 0) vfirst_seen = R->uzebox__DOT__video__DOT__vin;
			if (scanline == 224) { ref_prev = ref; ref_frames++; scanline = -999; }
		}
		prev_rise = cyc;
	}
	prev_pb0 = pb0;
}

// output capture (pixel clock)
static std::vector<uint8_t> out(720 * 480 * 3);
static int ox = 0, oy = 0, out_frames = 0, prev_vs = 0, prev_de = 0;
static std::string png_prefix;
static int png_every = 0;
static int checked = 0, bad = 0;

static void check_frame() {
	// picture rows: active lines 16 + 2y and 17 + 2y, y = 0..223, against the last reference frame
	int worst = 0;
	for (int y = 0; y < 224; y++)
		for (int k = 0; k < 2; k++)
			for (int x = 0; x < 720; x++) {
				uint8_t p = ref_prev[y * 1440 + 2 * x];
				uint8_t r = ((p & 7) << 5) | ((p & 7) << 2) | ((p & 7) >> 1);
				uint8_t g = (((p >> 3) & 7) << 5) | (((p >> 3) & 7) << 2) | (((p >> 3) & 7) >> 1);
				uint8_t b = ((p >> 6) & 3) * 0x55;
				const uint8_t *o = &out[((16 + 2 * y + k) * 720 + x) * 3];
				if (o[0] != r || o[1] != g || o[2] != b) worst++;
			}
	int lit = 0;
	for (uint8_t p : ref_prev) if (p) lit++;
	if (!lit) { printf("frame %d: blank (not counted)\n", out_frames); return; }
	checked++;
	if (worst) bad++;
	printf("frame %d: %d lit pixels, %d differ from the reference%s\n", out_frames, lit, worst, worst ? "" : " (OK)");
}

static void pix_capture() {
	int vs = top->vs, de = top->de;
	if (vs && !prev_vs) {
		if (oy == 480) {
			out_frames++;
			if (ref_frames >= 2) check_frame();
			if (!png_prefix.empty() && png_every && out_frames % png_every == 0) {
				char n[512]; snprintf(n, sizeof n, "%s_%04d.png", png_prefix.c_str(), out_frames);
				write_png(n, out.data(), 720, 480);
			}
		}
		oy = 0;
	}
	if (de) {
		if (ox < 720 && oy < 480) {
			uint8_t *o = &out[(oy * 720 + ox) * 3];
			o[0] = top->rgb >> 16; o[1] = top->rgb >> 8; o[2] = top->rgb;
		}
		ox++;
	} else if (prev_de) { ox = 0; oy++; }
	prev_vs = vs; prev_de = de;
}

// one CPU cycle (also the pixel clock)
static void cpu_cycle() {
	top->clk = 1; top->eval(); sram_eval(); top->eval();
	cyc++; ref_tick(); pix_capture();
	top->clk = 0; top->eval(); sram_eval(); top->eval();
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	crc_init();
	if (argc < 2) { fprintf(stderr, "usage: %s game.uze [-n frames] [-p png] [-e n] [-k f:n:key]\n", argv[0]); return 2; }
	int max_frames = 10, key_at = -1, key_n = 0, key = 0;
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "-n") && i + 1 < argc) max_frames = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-p") && i + 1 < argc) png_prefix = argv[++i];
		else if (!strcmp(argv[i], "-e") && i + 1 < argc) png_every = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-k") && i + 1 < argc) sscanf(argv[++i], "%d:%d:%x", &key_at, &key_n, &key);
	}
	if (!png_prefix.empty() && !png_every) png_every = 1;
	FILE *f = fopen(argv[1], "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
	std::vector<uint8_t> uze;
	int c; while ((c = fgetc(f)) != EOF) uze.push_back(c);
	fclose(f);
	for (auto &w : sram) w = 0x5A5A;          // the SRAM holds garbage at power up

	top = new Vuzebox;
	top->areset = 1; top->reset = 0; top->joy_l = 0; top->joy_r = 0; top->kbd = 0;
	for (int i = 0; i < 4; i++) cpu_cycle();
	top->areset = 0;
	for (int i = 0; i < 100; i++) cpu_cycle();

	// the load, as kg_mcu2: LD_START, then a byte every 8 clocks with LD_WR, LD_END
	top->ld_start = 1; top->ld_active = 1; cpu_cycle(); top->ld_start = 0;
	for (size_t i = 0; i < uze.size(); i++) {
		top->ld_addr = i; top->ld_data = uze[i]; top->ld_wr = 1; cpu_cycle(); top->ld_wr = 0;
		for (int k = 0; k < 7; k++) cpu_cycle();
	}
	top->ld_end = 1; top->ld_active = 0; cpu_cycle(); top->ld_end = 0;
	// the program in the SRAM must be the file
	int mism = 0;
	for (size_t i = 512; i < uze.size(); i++) {
		size_t p = i - 512;
		uint8_t b = (p & 1) ? sram[p >> 1] >> 8 : sram[p >> 1] & 0xFF;
		if (b != uze[i]) mism++;
	}
	printf("loaded %zu bytes, %d wrong in the SRAM\n", uze.size() - 512, mism);

	while (out_frames < max_frames) {
		if (key_at >= 0) {
			bool on = ref_frames >= key_at && ref_frames < key_at + key_n;
			top->kbd = on ? ((uint64_t)key << 8) : 0;
		}
		cpu_cycle();
	}
	printf("V_FIRST measured: %d (input line of picture row 0)\n", vfirst_seen);
	printf("%s: %d frames checked, %d with differences\n", bad || !checked ? "FAIL" : "OK", checked, bad);
	return bad || !checked || mism;
}
