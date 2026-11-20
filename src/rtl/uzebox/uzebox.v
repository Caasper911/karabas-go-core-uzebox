// uzebox.v - the Uzebox console without the board: ATmega644 (program memory in the board SRAM), the
// .uze loader, two SNES pads, the video (uze_video: lines of the game -> uze_fb: frame buffer in the board
// SDRAM -> CEA 720 x 480p in clk_vid) and the 8-bit sound.
//
// The CPU is held in reset until a game is loaded (an FL load of a .uze, kind 2), while a load runs and
// while `reset` is high (OSD Reset). Sound: the OCR2A sample the kernel writes once per line
// (15.7 kHz), unsigned 8 bit, as `audio` (two's complement 16 bit, a quarter of full scale, clk).
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uzebox #(
	parameter V_FIRST = 30
) (
	input             clk,            // CPU clock (28.75 MHz)
	input             clk_sdr,        // SDRAM clock (71.875 MHz)
	input             areset_sdr,     // clk_sdr domain
	input             clk_vid,        // video clock (27 MHz)
	input             areset,         // clk domain
	input             reset,          // OSD reset, clk domain

	input             ld_start,       // a new file (FL item of the game)
	input             ld_active,
	input             ld_end,
	input             ld_wr,
	input      [31:0] ld_addr,
	input      [7:0]  ld_data,

	input      [15:0] joy_l,
	input      [15:0] joy_r,
	input      [55:0] kbd,

	output     [20:0] sram_a,
	input      [15:0] sram_dq_i,
	output     [15:0] sram_dq_o,
	output            sram_dq_oe,
	output     [1:0]  sram_we_n,
	output     [1:0]  sram_oe_n,

	output     [12:0] sdr_a,
	output     [1:0]  sdr_ba,
	input      [15:0] sdr_dq_i,
	output     [15:0] sdr_dq_o,
	output     [15:0] sdr_dq_oe_n,
	output     [1:0]  sdr_dqm,
	output            sdr_ras_n,
	output            sdr_cas_n,
	output            sdr_we_n,

	output     [23:0] rgb,              // clk_vid
	output            hs,
	output            vs,
	output            de,

	output reg [15:0] audio,
	output            running,
	output     [15:0] dbg_pc
);

// ---------------------------------------------------------------- reset and load
reg loaded = 1'b0, cpu_rst = 1'b1;
wire loading = ld_active | ~loaded;
always @(posedge clk) begin
	if (areset) loaded <= 1'b0;
	else if (ld_start) loaded <= 1'b0;
	else if (ld_end) loaded <= 1'b1;
	cpu_rst <= areset | reset | ld_active | ~loaded;
end
assign running = ~cpu_rst;

// ---------------------------------------------------------------- the ATmega644
wire [14:0] pm_addr, pm_addr_nx;
wire [15:0] pm_rdata;
wire [7:0]  porta, ddra, ddrb, portd, ddrd, ocr2a;
wire [7:0]  pixel /* verilator public_flat */, portb /* verilator public_flat */;
wire [1:0]  pad_data;
wire        sample;

atmega644 mcu (
	.clk(clk), .rst(cpu_rst),
	.pm_addr(pm_addr), .pm_addr_nx(pm_addr_nx), .pm_rdata(pm_rdata),
	.pina({porta[7:2], pad_data}), .pinb(portb), .pinc(8'd0), .pind(portd),
	.porta(porta), .ddra(ddra), .portb(portb), .ddrb(ddrb), .pixel(pixel), .portd(portd), .ddrd(ddrd),
	.ocr2a(ocr2a), .sample(sample),
	.insn_start(), .dbg_pc(dbg_pc)
);

uze_pm_sram pm (
	.clk(clk), .loading(loading | cpu_rst),
	.pm_addr_nx(pm_addr_nx), .pm_rdata(pm_rdata),
	.ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data), .ld_busy(),
	.sram_a(sram_a), .sram_dq_i(sram_dq_i), .sram_dq_o(sram_dq_o), .sram_dq_oe(sram_dq_oe),
	.sram_we_n(sram_we_n), .sram_oe_n(sram_oe_n)
);

uze_pads pads (.clk(clk), .porta(porta), .joy_l(joy_l), .joy_r(joy_r), .kbd(kbd), .data(pad_data));

wire        line_tg;
wire [1:0]  line_bank;
wire [7:0]  line_row;
wire [11:0] ring_addr;
wire [7:0]  ring_data;
uze_video #(.V_FIRST(V_FIRST)) video (
	.clk(clk), .rst(areset), .pixel(cpu_rst ? 8'd0 : pixel), .sync(portb[0]),
	.line_tg(line_tg), .line_bank(line_bank), .line_row(line_row), .frame_start(),
	.rd_clk(clk_sdr), .rd_addr(ring_addr), .rd_data(ring_data)
);

wire        wb_cyc, wb_stb, wb_we, wb_ack, sdr_ready;
wire [3:0]  wb_sel;
wire [24:2] wb_adr;
wire [2:0]  wb_cti;
wire [31:0] wb_dat_w, wb_dat_r;
uze_fb fb (
	.clk_sdr(clk_sdr), .rst_sdr(areset_sdr), .sdr_ready(sdr_ready),
	.line_tg(line_tg), .line_bank(line_bank), .line_row(line_row), .rd_addr(ring_addr), .rd_data(ring_data),
	.wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_sel(wb_sel), .wb_adr(wb_adr), .wb_cti(wb_cti),
	.wb_dat_o(wb_dat_w), .wb_dat_i(wb_dat_r), .wb_ack(wb_ack),
	.clk_vid(clk_vid), .rgb(rgb), .hs(hs), .vs(vs), .de(de)
);

`ifdef UZE_SIM_SDRAM
// simulation: a wishbone RAM in place of the SDRAM controller (src/sim/system)
uze_wb_ram_sim sdram (
	.clk(clk_sdr), .reset(areset_sdr), .ready(sdr_ready),
	.wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_sel(wb_sel), .wb_adr(wb_adr), .wb_cti(wb_cti),
	.wb_dat_i(wb_dat_w), .wb_dat_o(wb_dat_r), .wb_ack(wb_ack)
);
assign sdr_a = 13'd0; assign sdr_ba = 2'd0; assign sdr_dq_o = 16'd0; assign sdr_dq_oe_n = 16'hFFFF;
assign sdr_dqm = 2'b11; assign sdr_ras_n = 1'b1; assign sdr_cas_n = 1'b1; assign sdr_we_n = 1'b1;
`else
uze_sdram sdram (
	.clk(clk_sdr), .reset(areset_sdr), .ready(sdr_ready),
	.wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_sel(wb_sel), .wb_adr(wb_adr), .wb_cti(wb_cti),
	.wb_dat_i(wb_dat_w), .wb_dat_o(wb_dat_r), .wb_ack(wb_ack),
	.sdr_a(sdr_a), .sdr_ba(sdr_ba), .sdr_dq_i(sdr_dq_i), .sdr_dq_o(sdr_dq_o), .sdr_dq_oe_n(sdr_dq_oe_n),
	.sdr_dqm(sdr_dqm), .sdr_ras_n(sdr_ras_n), .sdr_cas_n(sdr_cas_n), .sdr_we_n(sdr_we_n)
);
`endif

// ---------------------------------------------------------------- sound
reg sample_d = 1'b0;                 // OCR2A holds the new sample one clock after the write
always @(posedge clk) begin
	sample_d <= sample;
	if (cpu_rst) audio <= 16'd0;
	else if (sample_d) audio <= {{3{~ocr2a[7]}}, ocr2a[6:0], 6'd0};   // -12 dB: full scale was too loud (26112004)
end

endmodule
