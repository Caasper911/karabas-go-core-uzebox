// uzebox.v - the Uzebox console without the board: ATmega644 (program memory in the board SRAM), the
// .uze loader, two SNES pads, the 1440 x 480 video and the 8-bit sound.
//
// The CPU is held in reset until a game is loaded (an FL load of a .uze, kind 2), while a load runs and
// while `reset` is high (OSD Reset). Sound: the OCR2A sample the kernel writes once per line
// (15.7 kHz), unsigned 8 bit, as `audio` (two's complement 16 bit, clk).
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uzebox #(
	parameter V_FIRST = 30
) (
	input             clk,            // CPU clock (28.75 MHz)
	input             clk_pix,        // 2 x clk, same PLL
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

	output     [23:0] rgb,
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

uze_video #(.V_FIRST(V_FIRST)) video (
	.clk(clk), .rst(areset), .pixel(cpu_rst ? 8'd0 : pixel), .sync(portb[0]),
	.clk_pix(clk_pix), .rgb(rgb), .hs(hs), .vs(vs), .de(de), .frame_start()
);

// ---------------------------------------------------------------- sound
reg sample_d = 1'b0;                 // OCR2A holds the new sample one clock after the write
always @(posedge clk) begin
	sample_d <= sample;
	if (cpu_rst) audio <= 16'd0;
	else if (sample_d) audio <= {~ocr2a[7], ocr2a[6:0], 8'h00};
end

endmodule
