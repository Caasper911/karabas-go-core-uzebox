// png.h - minimal PNG writer (stored deflate blocks, RGB 8 bit) for the test benches.
// karabas-go-core-uzebox, GPL-3.0-or-later.
#pragma once
#include <cstdio>
#include <cstdint>
#include <vector>

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

