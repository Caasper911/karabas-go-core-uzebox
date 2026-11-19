// uze_video.v - the Uzebox picture (PORTC) doubled to 720 x 480 in the CPU clock (variant V3 of
// docs/PLAN.md, user 2026-11-20: 1440 x 480 at 2x the clock was refused by the monitors): one output
// pixel per two CPU cycles (the first of the pair, as Uzem draws), 910 x 524 clocks, 31.6 kHz, 60.3 Hz
// at 28.75 MHz, syncs always present.
//
// Input: hc / vin count the input line (1820 cycles) and frame (262 lines) and run free; they lock to
// the sync of the kernel (PB0): a rising edge 1820 cycles after the last one starts a line (hc = 0);
// edges 910 cycles apart are the half lines of the vertical sync: the first one of a frame makes the
// current line number 0. Picture pixel x of input line vin = the cycle H_FIRST + 2x after the line
// start (the window of Uzem), x = 0..719, written into bank vin[0] of a two-line buffer.
// Output: two output lines per input line (the first and second half of hc), so the output is
// genlocked with no frame buffer; it shows the previous, complete input line from the other bank.
// Picture row y = input line y + V_FIRST, 224 rows, doubled to 448 lines in the middle of the 480
// active lines.
// Output timing (clocks): line 910: hsync 0..61, active 148..867; frame 524: vsync 0..5, active
// 36..515; picture lines 52..499. hs / vs / de high active, 2 clocks after the counters.
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uze_video #(
	parameter H_FIRST = 168,          // first picture cycle after the rise of PB0 (Uzem VIDEO_LEFT_EDGE)
	parameter V_FIRST = 30            // input line of picture row 0 (line 0 = first half line of vsync)
) (
	input             clk,
	input             rst,
	input      [7:0]  pixel,
	input             sync,           // PB0

	output reg [23:0] rgb,
	output reg        hs,
	output reg        vs,
	output reg        de,
	output            frame_start     // one cycle at line 0 (debug, test bench)
);

localparam H_TOTAL = 1820, H_HALF = 910;
localparam O_TOTAL = 524, O_ACT = 36, O_PIC = 52;
localparam HS_END = 62, HA = 148;
// output line of input line 0 = (O_PIC - 2 * (V_FIRST + 1)) mod 524: picture row 0 (input line
// V_FIRST, shown during input line V_FIRST + 1) on output line O_PIC
localparam integer VOFS_I = O_PIC - 2 * (V_FIRST + 1);
localparam [9:0] VOFS = (VOFS_I % O_TOTAL + O_TOTAL) % O_TOTAL;

// ---------------------------------------------------------------- input
reg [10:0] hc /* verilator public_flat */ = 11'd0;
reg [8:0]  vin /* verilator public_flat */ = 9'd0;
reg [11:0] per = 12'd0;          // cycles since the last rise of PB0
reg        sync_d = 1'b0;
reg        in_vs = 1'b0;         // inside the half lines of the vertical sync
wire       rise = sync & ~sync_d;
wire       full = rise && per == H_TOTAL - 1;
wire       half = rise && per == H_HALF - 1;
wire       wrap = hc == H_TOTAL - 1;
assign frame_start = half && !in_vs;

always @(posedge clk) begin
	sync_d <= sync;
	if (rise) per <= 12'd0;
	else if (per != 12'hFFF) per <= per + 12'd1;
	if (rst) begin
		hc <= 11'd0; vin <= 9'd0; in_vs <= 1'b0;
	end else begin
		if (full && hc != 11'd0) begin                  // line start out of phase: realign
			hc <= 11'd1;
			vin <= (vin == 9'd261) ? 9'd0 : vin + 9'd1;
		end else begin
			hc <= wrap ? 11'd0 : hc + 11'd1;
			if (wrap) vin <= (vin == 9'd261) ? 9'd0 : vin + 9'd1;
		end
		if (half && !in_vs) vin <= 9'd0;                // first half line: this is line 0
		if (half) in_vs <= 1'b1;
		else if (full) in_vs <= 1'b0;
	end
end

// two-line buffer: bank vin[0], 720 pixels (1024 bytes) each, one RAMB16
reg  [7:0]  lbuf [0:2047];
wire [10:0] wx = hc - H_FIRST;
wire        wen = hc >= H_FIRST && hc < H_FIRST + 1440 && !wx[0];
always @(posedge clk)
	if (wen) lbuf[{vin[0], wx[10:1]}] <= pixel;

// ---------------------------------------------------------------- output
wire        hh = hc >= H_HALF;
wire [9:0]  ho = hh ? hc - H_HALF : hc;                     // 0..909
wire [9:0]  lo = {vin, hh};                                 // 0..523
wire [10:0] vsum = lo + VOFS;
wire [9:0]  vo = (vsum >= O_TOTAL) ? vsum - O_TOTAL : vsum;
wire [8:0]  row = vin - 9'd1 - V_FIRST;                     // input line shown, as a picture row
wire        pic = vo >= O_PIC && vo < O_PIC + 448 && row < 9'd224;
wire        act_h = ho >= HA && ho < HA + 720;
wire        act_v = vo >= O_ACT && vo < O_ACT + 480;
wire [9:0]  rx = ho - HA;

reg  [7:0] px;
reg        hs1, vs1, de1, pic1;
always @(posedge clk) begin
	px <= lbuf[{~vin[0], rx}];
	hs1 <= ho < HS_END;
	vs1 <= vo < 10'd6;
	de1 <= act_h && act_v;
	pic1 <= act_h && act_v && pic;
	hs <= hs1; vs <= vs1; de <= de1;
	rgb <= pic1 ? {px[2:0], px[2:0], px[2:1], px[5:3], px[5:3], px[5:4], px[7:6], px[7:6], px[7:6], px[7:6]}
	            : 24'd0;
end

endmodule
