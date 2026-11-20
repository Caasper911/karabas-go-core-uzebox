// tb_system.cpp - the whole console (uzebox.v, built with UZE_SIM_SDRAM: a wishbone RAM in place of the
// SDRAM controller) with a model of the async board SRAM, in its three clocks (CPU 28.75 MHz, SDRAM
// 71.875 MHz, video 27 MHz). Loads a .uze through the LD_* loader ports (as kg_mcu2: a byte every 8 CPU
// clocks), runs it and checks the 720 x 480p output: the picture rows (active lines 16 + 2y, 17 + 2y,
// pixel x = cycle 168 + 2x after the rise of PB0) must equal one of the last reference frames, taken from
// PORTC / PB0 the way Uzem does (rows from the 38th line after the first half line). Frames may be
// dropped or repeated (game 60.29 Hz, output 59.94 Hz), a torn frame matches none. Saves PNG frames.
// karabas-go-core-uzebox, GPL-3.0-or-later.
//
// Usage: tb_system <game.uze> [-n output_frames] [-p png_prefix] [-e every] [-k start_frame:frames:usb_key]

#include "Vuzebox.h"
#include "Vuzebox___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <map>
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

// ------------------------------------------------------------------ reference: Uzem's window
static uint8_t linebuf[2048];
static std::vector<uint8_t> ref(1440 * 224);
static std::vector<std::vector<uint8_t>> refs;          // the last complete reference frames
static int scanline = -999, ref_frames = 0;
static uint64_t prev_rise = 0, line_start = 0;
static int prev_pb0 = 0;
static std::map<uint64_t, uint64_t> rise_hist;
static int ext_x0 = 99999, ext_x1 = -1, ext_y0 = 99999, ext_y1 = -99999;   // where the game draws
static void ref_tick() {
	auto *R = top->rootp;
	linebuf[cyc & 0x7FF] = R->uzebox__DOT__pixel;
	if (R->uzebox__DOT__pixel && scanline != -999) {
		int x = (int)(cyc - line_start), y = scanline;
		if (x < ext_x0) ext_x0 = x; if (x > ext_x1) ext_x1 = x;
		if (y < ext_y0) ext_y0 = y; if (y > ext_y1) ext_y1 = y;
	}
	int pb0 = R->uzebox__DOT__portb & 1;
	if (pb0 && !prev_pb0) {
		uint64_t el = cyc - prev_rise;
		rise_hist[el]++;
		if (scanline == -999 && el >= 895 && el <= 925) scanline = -38;
		else if (scanline != -999) {
			if (scanline >= 0 && scanline < 224)
				for (int i = 0; i < 1440; i++) ref[scanline * 1440 + i] = linebuf[(line_start + 168 + i) & 0x7FF];
			scanline++;
			line_start = cyc;
			if (scanline == 224) {
				refs.push_back(ref);
				if (refs.size() > 4) refs.erase(refs.begin());
				ref_frames++;
				scanline = -999;
			}
		}
		prev_rise = cyc;
	}
	prev_pb0 = pb0;
}

static void rgb332(uint8_t p, uint8_t *o) {
	o[0] = ((p & 7) << 5) | ((p & 7) << 2) | ((p & 7) >> 1);
	o[1] = (((p >> 3) & 7) << 5) | (((p >> 3) & 7) << 2) | (((p >> 3) & 7) >> 1);
	o[2] = ((p >> 6) & 3) * 0x55;
}

// ------------------------------------------------------------------ output capture (video clock)
static std::vector<uint8_t> out(720 * 480 * 3);
static int ox = 0, oy = 0, out_frames = 0, prev_vs = 0, prev_de = 0;
static std::string png_prefix;
static int png_every = 0;
static int checked = 0, bad = 0, shown = 0;

static void check_frame() {
	bool any = false;
	for (int y = 16; y < 464 && !any; y++)
		for (int x = 0; x < 720 && !any; x++) {
			const uint8_t *o = &out[(y * 720 + x) * 3];
			if (o[0] | o[1] | o[2]) any = true;
		}
	if (!any) { printf("frame %d: black\n", out_frames); return; }
	shown++;
	int best = -1, best_diff = 1 << 30;
	for (size_t r = 0; r < refs.size(); r++) {
		int diff = 0;
		for (int y = 0; y < 224; y++)
			for (int k = 0; k < 2; k++)
				for (int x = 0; x < 720; x++) {
					uint8_t c[3]; rgb332(refs[r][y * 1440 + 2 * x], c);
					const uint8_t *o = &out[((16 + 2 * y + k) * 720 + x) * 3];
					if (o[0] != c[0] || o[1] != c[1] || o[2] != c[2]) diff++;
				}
		if (diff < best_diff) { best_diff = diff; best = (int)r; }
	}
	checked++;
	if (best_diff) bad++;
	printf("frame %d: %s (reference -%d, %d pixels differ)\n", out_frames, best_diff ? "DIFFERS" : "OK",
	       (int)refs.size() - 1 - best, best_diff);
}

static void vid_capture() {
	int vs = top->vs, de = top->de;
	if (vs && !prev_vs) {
		if (oy == 480) {
			out_frames++;
			if (refs.size() >= 2) check_frame();
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

// ------------------------------------------------------------------ the file mounter of the MCU (kg_mcu2 SDC_*)
// Slot 1: the SD image (-i), mounted at the start; slot 2: the EEPROM file of kg_bk_ram (-s, else 2 KB of zeros),
// mounted when the core asks (bk_mount). One request at a time, the lowest slot first, served after a delay like
// the MCU (IMG_DELAY clocks): a read sector comes as 512 sdc_byte_in_strobe, a written one is read through
// sdc_byte_addr / sdc_byte_out_data (4 clocks per byte), then sdc_done.
static std::vector<uint8_t> files[8];
static std::vector<uint8_t> rom;
static int boot_loader = 0;
static const char *sav_out = nullptr;
static bool mounted[8];
static int img_state = 0, img_i = 0, img_wait = 0, img_slot = 0;
static uint32_t img_lba = 0;
static int img_reads = 0, img_writes = 0, bk_mounts = 0;
static const int IMG_DELAY = 6000;
static void img_tick() {
	top->sdc_done = 0; top->sdc_byte_in_strobe = 0; top->sdc_img_mounted = 0; top->sdc_error = 0;
	if (!files[1].empty() && !mounted[1] && cyc > 50) {
		top->sdc_img_mounted = 1 << 1; top->sdc_img_size = files[1].size(); mounted[1] = true; return;
	}
	if (top->bk_mount && !mounted[2]) {
		if (files[2].empty()) files[2].assign(2048, 0);
		top->sdc_img_mounted = 1 << 2; top->sdc_img_size = files[2].size(); mounted[2] = true; bk_mounts++; return;
	}
	std::vector<uint8_t> &f = files[img_slot];
	switch (img_state) {
	case 0: {
		int rq = top->sdc_rd | top->sdc_wr;
		for (int sl = 0; sl < 8; sl++) if (rq & (1 << sl)) {
			img_slot = sl; img_state = (top->sdc_rd & (1 << sl)) ? 1 : 3; img_lba = top->sdc_sector;
			img_wait = IMG_DELAY; img_i = 0; top->sdc_busy = 1; top->sdc_slot = sl;
			break;
		}
		break;
	}
	case 1:                                   // read: wait, then the bytes
		if (img_wait) { img_wait--; break; }
		if ((cyc & 3) == 0) {
			size_t a = (size_t)img_lba * 512 + img_i;
			top->sdc_byte_addr = img_i; top->sdc_byte_in_data = a < f.size() ? f[a] : 0; top->sdc_byte_in_strobe = 1;
			if (++img_i == 512) { img_state = 2; img_reads++; }
		}
		break;
	case 2: top->sdc_done = 1; top->sdc_busy = 0; img_state = 0; break;
	case 3:                                   // write: wait, then each byte: its address, 3 clocks, the byte
		if (img_wait) { img_wait--; break; }
		if (img_i < 512 * 4) {
			int b = img_i >> 2;
			top->sdc_byte_addr = b;
			if ((img_i & 3) == 3) { size_t a = (size_t)img_lba * 512 + b; if (a < f.size()) f[a] = top->sdc_byte_out_data; }
			img_i++;
		} else { img_state = 2; img_writes++; }
		break;
	}
}

// ------------------------------------------------------------------ clocks (ps)
static const uint64_t HALF_CPU = 17391, HALF_SDR = 6957, HALF_VID = 18519;
static uint64_t t_cpu = HALF_CPU, t_sdr = HALF_SDR, t_vid = HALF_VID;
static uint64_t snd_changes = 0; static uint16_t snd_last = 0;

// advance to the next rising edge of the CPU clock, running the other clocks on the way
static void cpu_cycle() {
	for (;;) {
		uint64_t t = t_cpu < t_sdr ? t_cpu : t_sdr;
		if (t_vid < t) t = t_vid;
		bool cpu_rise = false, vid_rise = false;
		if (t_cpu == t) { top->clk = !top->clk; cpu_rise = top->clk; t_cpu += HALF_CPU; }
		if (t_sdr == t) { top->clk_sdr = !top->clk_sdr; t_sdr += HALF_SDR; }
		if (t_vid == t) { top->clk_vid = !top->clk_vid; vid_rise = top->clk_vid; t_vid += HALF_VID; }
		top->eval(); sram_eval(); top->eval();
		if (vid_rise) vid_capture();
		if (cpu_rise) {
			cyc++; ref_tick(); img_tick();
			if (top->audio != snd_last) { snd_changes++; snd_last = top->audio; }
			return;
		}
	}
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	crc_init();
	if (argc < 2) { fprintf(stderr, "usage: %s game.uze [-n frames] [-p png] [-e n] [-k f:n:key]\n", argv[0]); return 2; }
	int max_frames = 10;
	std::vector<int> k_at, k_n, k_key;      // -k frame:frames:usb_key, may repeat
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "-n") && i + 1 < argc) max_frames = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-p") && i + 1 < argc) png_prefix = argv[++i];
		else if (!strcmp(argv[i], "-e") && i + 1 < argc) png_every = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-k") && i + 1 < argc) {
			int a = 0, n = 0, k = 0; sscanf(argv[++i], "%d:%d:%x", &a, &n, &k);
			k_at.push_back(a); k_n.push_back(n); k_key.push_back(k);
		}
		else if (!strcmp(argv[i], "-i") && i + 1 < argc) {
			FILE *fi = fopen(argv[++i], "rb");
			if (!fi) { fprintf(stderr, "cannot open %s\n", argv[i]); return 2; }
			int ch; while ((ch = fgetc(fi)) != EOF) files[1].push_back(ch);
			fclose(fi);
		} else if (!strcmp(argv[i], "-b") && i + 1 < argc) {      // the Bootloader5 ROM (raw load at 0xF000)
			FILE *fi = fopen(argv[++i], "rb");
			if (!fi) { fprintf(stderr, "cannot open %s\n", argv[i]); return 2; }
			int ch; while ((ch = fgetc(fi)) != EOF) rom.push_back(ch);
			fclose(fi);
		} else if (!strcmp(argv[i], "-L")) boot_loader = 1;      // Boot = Loader
		else if (!strcmp(argv[i], "-E") && i + 1 < argc) sav_out = argv[++i];   // the EEPROM file at the end
		else if (!strcmp(argv[i], "-s") && i + 1 < argc) {        // the EEPROM file to start with
			FILE *fi = fopen(argv[++i], "rb");
			if (!fi) { fprintf(stderr, "cannot open %s\n", argv[i]); return 2; }
			int ch; while ((ch = fgetc(fi)) != EOF) files[2].push_back(ch);
			fclose(fi);
		}
	}
	if (!png_prefix.empty() && !png_every) png_every = 1;
	FILE *f = fopen(argv[1], "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
	std::vector<uint8_t> uze;
	int c; while ((c = fgetc(f)) != EOF) uze.push_back(c);
	fclose(f);
	for (auto &w : sram) w = 0x5A5A;          // the SRAM holds garbage at power up

	top = new Vuzebox;
	top->areset = 1; top->areset_sdr = 1; top->reset = 0; top->joy_l = 0; top->joy_r = 0; top->kbd = 0;
	top->sd_image = files[1].empty() ? 0 : 1; top->boot = boot_loader; top->img_flush = 0; top->sd_miso = 1;   // the image if one is given, else no card (MISO high)
	top->clk = 0; top->clk_sdr = 0; top->clk_vid = 0;
	for (int i = 0; i < 8; i++) cpu_cycle();
	top->areset = 0; top->areset_sdr = 0;
	for (int i = 0; i < 100; i++) cpu_cycle();

	if (!rom.empty()) {                       // the ROM of the .kg first (raw, at 0xF000), as the MCU does
		top->ld_raw = 1; top->ld_start = 1; top->ld_active = 1; cpu_cycle(); top->ld_start = 0;
		for (size_t i = 0; i < rom.size(); i++) {
			top->ld_addr = 0xF000 + i; top->ld_data = rom[i]; top->ld_wr = 1; cpu_cycle(); top->ld_wr = 0;
			for (int k = 0; k < 7; k++) cpu_cycle();
		}
		top->ld_end = 1; top->ld_active = 0; cpu_cycle(); top->ld_end = 0; top->ld_raw = 0;
	}
	top->ld_start = 1; top->ld_active = 1; cpu_cycle(); top->ld_start = 0;
	for (size_t i = 0; i < uze.size(); i++) {
		top->ld_addr = i; top->ld_data = uze[i]; top->ld_wr = 1; cpu_cycle(); top->ld_wr = 0;
		for (int k = 0; k < 7; k++) cpu_cycle();
	}
	top->ld_end = 1; top->ld_active = 0; cpu_cycle(); top->ld_end = 0;
	int mism = 0;
	for (size_t i = 512; i < uze.size(); i++) {
		size_t p = i - 512;
		uint8_t b = (p & 1) ? sram[p >> 1] >> 8 : sram[p >> 1] & 0xFF;
		if (b != uze[i]) mism++;
	}
	printf("loaded %zu bytes, %d wrong in the SRAM\n", uze.size() - 512, mism);
	if (!rom.empty()) printf("ROM: sram[0x7800] %04x (rom %02x%02x)\n", sram[0x7800], rom[1], rom[0]);
	if (getenv("PCDBG")) {
		int n = 0;
		while (!top->running && n < 2000000) { cpu_cycle(); n++; }
		printf("CPU runs after %d clocks, pc", n);
		for (int i = 0; i < 16; i++) { printf(" %04x", top->dbg_pc); cpu_cycle(); }
		printf("\n");
		// the first jump out of the boot section (0x7800..) while the CPU runs
		int prev = top->dbg_pc, prun = top->running;
		for (int i = 0; i < 3000000; i++) {
			cpu_cycle();
			int pc = top->dbg_pc, run = top->running;
			if (run != prun) printf("cycle %llu: running %d (pc %04x)\n", (unsigned long long)cyc, run, pc);
			if (run && prun && prev >= 0x7800 && pc < 0x7800) {
				printf("cycle %llu: pc %04x -> %04x, SREG I %d\n", (unsigned long long)cyc, prev, pc,
				       (int)(top->rootp->uzebox__DOT__mcu__DOT__cpu__DOT__sreg >> 7) & 1);
				break;
			}
			prev = pc; prun = run;
		}
	}

	while (out_frames < max_frames) {
		uint64_t kb = 0;
		for (size_t q = 0; q < k_at.size(); q++)
			if (ref_frames >= k_at[q] && ref_frames < k_at[q] + k_n[q]) kb = (uint64_t)k_key[q] << 8;
		top->kbd = kb;
		cpu_cycle();
		if (getenv("PCDBG") && top->running && (cyc % 200000) == 0) printf("cycle %llu: pc %04x, game frame %d, kbd %llx%c", (unsigned long long)cyc, top->dbg_pc, ref_frames, (unsigned long long)top->kbd, 10);
	}
	printf("audio: %llu changes\n", (unsigned long long)snd_changes);
	printf("PB0 rise intervals (cycles: count):");
	for (auto &h : rise_hist) if (h.second > 20) printf(" %llu:%llu", (unsigned long long)h.first, (unsigned long long)h.second);
	printf("%c", 10);
	printf("game draws: cycles %d..%d after the line start (window 168..1607), rows %d..%d (window 0..223)%c", ext_x0, ext_x1, ext_y0, ext_y1, 10);
	{ auto *R = top->rootp; printf("io: SPCR %02x SPSR %02x SPDR %02x DDRA %02x PORTA %02x DDRD %02x PORTD %02x UCSR0B %02x%c", R->uzebox__DOT__mcu__DOT__io__DOT__gen[0x2C], R->uzebox__DOT__mcu__DOT__io__DOT__gen[0x2D], R->uzebox__DOT__mcu__DOT__io__DOT__gen[0x2E], R->uzebox__DOT__mcu__DOT__io__DOT__gen[0x01], R->uzebox__DOT__mcu__DOT__io__DOT__gen[0x02], R->uzebox__DOT__mcu__DOT__io__DOT__gen[0x0A], R->uzebox__DOT__mcu__DOT__io__DOT__gen[0x0B], R->uzebox__DOT__mcu__DOT__io__DOT__gen[0xA1], 10); }
	printf("file mounter: %d sectors read, %d written, EEPROM file mounted %d times%c", img_reads, img_writes, bk_mounts, 10);
	if (sav_out) { FILE *fo = fopen(sav_out, "wb"); if (fo) { fwrite(files[2].data(), 1, files[2].size(), fo); fclose(fo); } }
	printf("SPI RAM: a byte late: %d%c", (int)top->rootp->uzebox__DOT__spiram__DOT__late_r, 10);
	printf("game frames %d, output frames %d, with a picture %d\n", ref_frames, out_frames, shown);
	printf("%s: %d frames checked, %d differ\n", bad || !checked ? "FAIL" : "OK", checked, bad);
	return bad || !checked || mism;
}
