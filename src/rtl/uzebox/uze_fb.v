// uze_fb.v - the frame buffer of the Uzebox picture in the board SDRAM and the 720 x 480p / 576p / 800 x 600
// output (user 2026-11-20: a frame buffer instead of an output locked to the game, standard timing;
// 576p 50 Hz and 800 x 600 60 Hz added 2026-11-21).
//
// Picture: 720 x 224 bytes (3:3:2), row y = one SDRAM row (1024 bytes): byte address
// { frame[1:0], y[7:0], x[9:0] }. Three frames (triple buffering): W is written, C is the last complete
// one, R is shown; at the end of row 223 C = W and W takes the frame that is neither C nor R; at the start
// of an output frame R = C. So a frame is never shown while it is written (no tearing); the game runs at
// 59.92 Hz (CPU 28.571 MHz): at 59.94 Hz a game frame is shown twice about every 50 s, at 60.32 Hz every
// 2.5 s, at 50 Hz 10 game frames a second are not shown.
//
// The SPI RAM of the console (uze_spiram) lives at byte 0x800000 (up to 8 MB), its single accesses go first.
// clk_sdr (72.727 MHz, uze_sdram, wishbone): the writer copies a picture line from the ring of
// uze_video (rd_*, 4 bytes into one 32-bit write) when line_tg toggles; the reader fills a line buffer
// (2 rows x 256 words) with 23 bursts of 8 words for a row the output asks for. The reader has priority.
// clk_vid, hs / vs / de high active (sync_pos: the polarity the screen wants), active area from (0, 0):
//   vmode 0: CEA-861 720 x 480p 59.94 Hz (VIC 2/3), 27 MHz: 858 x 525, hsync 736..797, vsync lines
//            489..494, negative syncs; picture rows 0..223 on the active lines 16..463, each twice;
//   vmode 1: CEA-861 720 x 576p 50 Hz (VIC 17/18), 27 MHz: 864 x 625, hsync 732..795, vsync lines 581..585,
//            negative; picture on the active lines 64..511;
//   vmode 2: VESA 800 x 600 60.32 Hz, 40 MHz (the board switches clk_vid): 1056 x 628, hsync 840..967, vsync
//            lines 601..604, positive syncs; picture at x 40..759 on the active lines 76..523.
// vmode (any clock) is taken at the end of an output frame. Black around and before the first complete frame.
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uze_fb (
	input             clk_sdr,
	input             rst_sdr,        // clk_sdr domain
	input             sdr_ready,      // uze_sdram init done

	// input side (uze_video, CPU clock; held for a whole input line)
	input             line_tg,
	input      [1:0]  line_bank,
	input      [7:0]  line_row,
	output     [11:0] rd_addr,
	input      [7:0]  rd_data,

	// the SPI RAM (uze_spiram, CPU clock): a request per toggle, single accesses at byte 0x800000 +
	input             sr_req_tg,
	input             sr_we,
	input      [20:0] sr_word,
	input      [1:0]  sr_lane,
	input      [7:0]  sr_byte,
	output reg        sr_ack_tg,
	output reg [31:0] sr_rdata,

	// wishbone master to uze_sdram
	output reg        wb_cyc,
	output reg        wb_stb,
	output reg        wb_we,
	output reg [3:0]  wb_sel,
	output reg [24:2] wb_adr,
	output reg [2:0]  wb_cti,
	output reg [31:0] wb_dat_o,
	input      [31:0] wb_dat_i,
	input             wb_ack,

	// output
	input             clk_vid,
	input      [1:0]  vmode,          // 0 720 x 480p 59.94 Hz, 1 720 x 576p 50 Hz, 2 800 x 600 60 Hz (40 MHz)
	output reg [23:0] rgb,
	output reg        hs,
	output reg        vs,
	output reg        de,
	output reg        sync_pos        // 1: the screen wants positive syncs (800 x 600)
);


// ---------------------------------------------------------------- video timing (clk_vid)
reg  [1:0] m_s0 = 2'd0, m_s1 = 2'd0, m_s2 = 2'd0;
reg  [1:0] m = 2'd0;                         // the mode of this output frame
wire       m5 = m == 2'd1, m8 = m == 2'd2;
wire [10:0] H_TOTAL = m8 ? 11'd1056 : m5 ? 11'd864 : 11'd858;
wire [10:0] H_ACT   = m8 ? 11'd800 : 11'd720;
wire [10:0] HS_B    = m8 ? 11'd840 : m5 ? 11'd732 : 11'd736;
wire [10:0] HS_E    = m8 ? 11'd968 : m5 ? 11'd796 : 11'd798;
wire [10:0] H_PIC   = m8 ? 11'd40 : 11'd0;   // first pixel of the picture
wire [9:0]  V_TOTAL = m8 ? 10'd628 : m5 ? 10'd625 : 10'd525;
wire [9:0]  V_ACT   = m8 ? 10'd600 : m5 ? 10'd576 : 10'd480;
wire [9:0]  VS_B    = m8 ? 10'd601 : m5 ? 10'd581 : 10'd489;
wire [9:0]  VS_E    = m8 ? 10'd605 : m5 ? 10'd586 : 10'd495;
wire [9:0]  V_PIC   = m8 ? 10'd76 : m5 ? 10'd64 : 10'd16;   // first active line of picture row 0

reg [10:0] hc = 11'd0;
reg [9:0] vc = 10'd0;
wire      hend = hc == H_TOTAL - 11'd1;
// requests to the SDRAM side: the frame start (R = C) and a row fetch (row, buffer bank = row[0])
reg       vfs_tg = 1'b0;
reg       rq_tg = 1'b0;
reg [7:0] rq_row = 8'd0;
wire [9:0] pl = vc - (V_PIC - 10'd2);        // a row is fetched during the two lines before it
always @(posedge clk_vid) begin
	m_s0 <= vmode; m_s1 <= m_s0; m_s2 <= m_s1;
	hc <= hend ? 11'd0 : hc + 11'd1;
	if (hend) vc <= (vc == V_TOTAL - 10'd1) ? 10'd0 : vc + 10'd1;
	if (hend && vc == V_TOTAL - 10'd1 && m_s2 == m_s1 && m_s2 != 2'd3) m <= m_s2;
	if (hc == 11'd0 && vc == 10'd0) vfs_tg <= ~vfs_tg;
	if (hc == 11'd0 && vc >= V_PIC - 10'd2 && vc < V_PIC + 10'd446 && !pl[0]) begin
		rq_tg <= ~rq_tg;
		rq_row <= pl[8:1];
	end
end

// ---------------------------------------------------------------- SDRAM side (clk_sdr)
reg [2:0] ltg_s = 3'd0, vfs_s = 3'd0, rq_s = 3'd0, sr_s = 3'd0;
initial begin sr_ack_tg = 1'b0; sr_rdata = 32'd0; end
always @(posedge clk_sdr) begin
	sr_s <= {sr_s[1:0], sr_req_tg};
	ltg_s <= {ltg_s[1:0], line_tg};
	vfs_s <= {vfs_s[1:0], vfs_tg};
	rq_s <= {rq_s[1:0], rq_tg};
end
wire line_ev = ltg_s[2] ^ ltg_s[1];
wire vfs_ev = vfs_s[2] ^ vfs_s[1];
wire rq_ev = rq_s[2] ^ rq_s[1];
wire sr_ev = sr_s[2] ^ sr_s[1];
reg  sr_pend = 1'b0;

// triple buffer
reg [1:0] fw = 2'd0, fc = 2'd1, fr = 2'd2;
reg       c_valid = 1'b0, r_valid = 1'b0;

// writer: one pending line (the next one comes 4500 clocks later, a copy takes ~2200)
reg        w_pend = 1'b0;
reg [1:0]  w_bank = 2'd0;
reg [7:0]  w_row = 8'd0;
reg        w_busy = 1'b0;
reg [9:0]  w_x = 10'd0;              // next byte of the ring to read
reg [2:0]  w_k = 3'd0;               // bytes of the word in flight (0..4), +1 for the BRAM latency
reg [31:0] w_word = 32'd0;
reg        w_full = 1'b0;            // w_word is ready to be written
reg [9:0]  w_wx = 10'd0;             // byte address of w_word
assign rd_addr = {w_bank, w_x};

// reader
reg        r_pend = 1'b0;
reg [7:0]  r_row = 8'd0;
reg [4:0]  r_burst = 5'd0;           // 0..22
reg [2:0]  r_word = 3'd0;            // word of the burst
reg        r_busy = 1'b0;

// the line buffer: 2 rows x 256 words (one RAMB16), written here, read in clk_vid
reg [31:0] lb [0:511];
reg        lb_we = 1'b0;
reg [8:0]  lb_wa = 9'd0;
reg [31:0] lb_wd = 32'd0;
always @(posedge clk_sdr)
	if (lb_we) lb[lb_wa] <= lb_wd;

// bus owner of the current transaction: 0 none, 1 reader burst, 2 writer word
reg [1:0]  own = 2'd0;

always @(posedge clk_sdr) begin
	lb_we <= 1'b0;
	if (rst_sdr) begin
		w_pend <= 1'b0; w_busy <= 1'b0; w_full <= 1'b0; r_pend <= 1'b0; r_busy <= 1'b0; own <= 2'd0;
		wb_cyc <= 1'b0; wb_stb <= 1'b0; sr_pend <= 1'b0; fw <= 2'd0; fc <= 2'd1; fr <= 2'd2; c_valid <= 1'b0; r_valid <= 1'b0;
	end else begin
		if (line_ev) begin w_pend <= 1'b1; w_bank <= line_bank; w_row <= line_row; end
		if (rq_ev) begin r_pend <= 1'b1; r_row <= rq_row; end
		if (sr_ev) sr_pend <= 1'b1;
		if (vfs_ev) begin fr <= fc; r_valid <= c_valid; end

		// ---- writer: bytes from the ring into w_word (ring read latency 1)
		if (!w_busy) begin
			if (w_pend && !line_ev) begin
				w_pend <= 1'b0; w_busy <= 1'b1; w_x <= 10'd0; w_k <= 3'd0; w_full <= 1'b0;
			end
		end else if (!w_full) begin
			// address w_x goes to the ring now; its byte comes next clock (w_k counts the bytes in)
			if (w_k != 3'd0) w_word <= {rd_data, w_word[31:8]};
			if (w_k == 3'd4) begin
				w_full <= 1'b1; w_wx <= w_x - 10'd4; w_k <= 3'd0;
			end else begin
				w_k <= w_k + 3'd1;
				w_x <= w_x + 10'd1;
			end
		end

		// ---- bus
		case (own)
			2'd0: if (sdr_ready) begin
				if (sr_pend) begin
					own <= 2'd3; sr_pend <= 1'b0;
					wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_we <= sr_we; wb_cti <= 3'b111;
					wb_adr <= {1'b0, 1'b1, sr_word};                   // byte 0x800000 + 4 * word
					wb_sel <= sr_we ? (4'b0001 << sr_lane) : 4'b1111;
					wb_dat_o <= {4{sr_byte}};
				end else if (r_pend || r_busy) begin
					if (!r_busy) begin r_busy <= 1'b1; r_pend <= 1'b0; r_burst <= 5'd0; end
					own <= 2'd1; r_word <= 3'd0;
					wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_we <= 1'b0; wb_cti <= 3'b010; wb_sel <= 4'b1111;
					wb_adr <= {5'd0, fr, r_row, r_busy ? r_burst : 5'd0, 3'd0};
				end else if (w_full) begin
					own <= 2'd2;
					wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_we <= 1'b1; wb_cti <= 3'b111; wb_sel <= 4'b1111;
					wb_adr <= {5'd0, fw, w_row, w_wx[9:2]};
					wb_dat_o <= w_word;
				end
			end
			2'd1: if (wb_ack) begin
				lb_we <= 1'b1; lb_wa <= {r_row[0], r_burst, r_word}; lb_wd <= wb_dat_i;
				r_word <= r_word + 3'd1;
				if (r_word == 3'd7) begin
					wb_cyc <= 1'b0; wb_stb <= 1'b0; own <= 2'd0;
					r_burst <= r_burst + 5'd1;
					if (r_burst == 5'd22) r_busy <= 1'b0;
				end
			end
			2'd3: if (wb_ack) begin
				wb_cyc <= 1'b0; wb_stb <= 1'b0; own <= 2'd0;
				sr_rdata <= wb_dat_i; sr_ack_tg <= ~sr_ack_tg;
			end
			default: if (wb_ack) begin
				wb_cyc <= 1'b0; wb_stb <= 1'b0; own <= 2'd0; w_full <= 1'b0;
				if (w_wx == 10'd716) begin                  // the last word of the line
					w_busy <= 1'b0;
					if (w_row == 8'd223) begin
						fc <= fw; c_valid <= 1'b1;
						fw <= (fw != 2'd0 && fr != 2'd0) ? 2'd0 : (fw != 2'd1 && fr != 2'd1) ? 2'd1 : 2'd2;
					end
				end
			end
		endcase
	end
end

// ---------------------------------------------------------------- output pixels (clk_vid)
reg  [2:0] rv_s = 3'd0;
always @(posedge clk_vid) rv_s <= {rv_s[1:0], r_valid};
wire [9:0] prow2 = vc - V_PIC;
wire [10:0] px = hc - H_PIC;                 // the picture x (0..719 inside it)
wire       pic = vc >= V_PIC && vc < V_PIC + 10'd448 && hc >= H_PIC && px < 11'd720;
reg  [31:0] lw;
reg  [1:0] bsel;
reg        hs1, vs1, de1, pic1;
always @(posedge clk_vid) begin
	lw <= lb[{prow2[1], px[9:2]}];                    // row y = prow2 >> 1, buffer bank y[0] = prow2[1]
	bsel <= px[1:0];
	hs1 <= hc >= HS_B && hc < HS_E;
	vs1 <= vc >= VS_B && vc < VS_E;
	de1 <= hc < H_ACT && vc < V_ACT;
	pic1 <= pic && rv_s[2];
	hs <= hs1; vs <= vs1; de <= de1; sync_pos <= m8;
	if (pic1) begin
		case (bsel)
			2'd0: rgb <= rgb332(lw[7:0]);
			2'd1: rgb <= rgb332(lw[15:8]);
			2'd2: rgb <= rgb332(lw[23:16]);
			default: rgb <= rgb332(lw[31:24]);
		endcase
	end else rgb <= 24'd0;
end

function [23:0] rgb332;
	input [7:0] p;
	begin
		rgb332 = {p[2:0], p[2:0], p[2:1], p[5:3], p[5:3], p[5:4], p[7:6], p[7:6], p[7:6], p[7:6]};
	end
endfunction

endmodule
