// uze_video.v - the input side of the Uzebox video: finds the lines and frames of the picture the kernel
// draws on PORTC / PB0 and keeps the last lines in a ring for the frame buffer (uze_fb.v).
//
// hc / vin count the input line (1820 cycles) and frame (262 lines) and run free; they lock to the sync
// of the kernel (PB0). Line lengths differ between kernels (old ones: 1818 cycles, SOLITAIR 2015): any
// rise 1790..1850 cycles after the last one starts a line, 895..925 after is a half line of the vertical
// sync; the first half line at least 200 lines after the last frame start makes the current line number
// 0 (as Uzem). Picture pixel x of an input line = the cycle H_FIRST + 2x after its start (the window of
// Uzem; variant V3: one pixel per two CPU cycles), x = 0..719, written into bank lc of a 4-line ring.
// When a line of picture row y = vin - V_FIRST (0..223) of a frame whose start was seen ends, line_tg toggles with line_bank / line_row
// (held until the next line): the frame buffer copies the bank, read through rd_* in its own clock.
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uze_video #(
	parameter H_FIRST = 168,          // first picture cycle after the rise of PB0 (Uzem VIDEO_LEFT_EDGE)
	parameter V_FIRST = 30            // input line of picture row 0 (line 0 = first half line of vsync)
) (
	input             clk,            // CPU clock
	input             rst,
	input      [7:0]  pixel,
	input             sync,           // PB0

	output reg        line_tg,        // toggles when a picture line is in the ring
	output reg [1:0]  line_bank,
	output reg [7:0]  line_row,       // 0..223
	output            frame_start,    // one cycle at input line 0 (debug, test bench)

	input             rd_clk,         // the frame buffer side
	input      [11:0] rd_addr,        // { bank, x }
	output reg [7:0]  rd_data
);

localparam H_TOTAL = 1820, H_HALF = 910;

reg [10:0] hc /* verilator public_flat */ = 11'd0;
reg [8:0]  vin /* verilator public_flat */ = 9'd0;
reg [1:0]  lc = 2'd0;            // input lines mod 4: the bank being written
reg [11:0] per = 12'd0;          // cycles since the last rise of PB0
reg [8:0]  since = 9'h1FF;       // input lines since the last frame start (saturating)
reg        sync_d = 1'b0;
reg        in_vs = 1'b0;         // inside the half lines of the vertical sync
wire       rise = sync & ~sync_d;
wire       full = rise && per >= 12'd1789 && per <= 12'd1849;
wire       half = rise && per >= 12'd894 && per <= 12'd924;
wire       wrap = hc == H_TOTAL - 1;
wire       realign = full && hc != 11'd0;
// a line ends at the wrap or at a realign late in the line (a realign early in it follows a wrap)
wire       line_end = wrap || (realign && hc >= H_HALF);
assign frame_start = half && !in_vs && since >= 9'd200;
wire [8:0] row = vin - V_FIRST;

initial begin line_tg = 1'b0; line_bank = 2'd0; line_row = 8'd0; end

always @(posedge clk) begin
	sync_d <= sync;
	if (rise) per <= 12'd0;
	else if (per != 12'hFFF) per <= per + 12'd1;
	if (rst) begin
		hc <= 11'd0; vin <= 9'd0; in_vs <= 1'b0;
	end else begin
		hc <= realign ? 11'd1 : wrap ? 11'd0 : hc + 11'd1;     // the rise is cycle 0 of the line
		if (line_end) begin
			vin <= (vin == 9'd261) ? 9'd0 : vin + 9'd1;
			lc <= lc + 2'd1;
			if (since != 9'h1FF) since <= since + 9'd1;
			// only lines of a frame whose start was seen (before the lock the line numbers are not the game's)
			if (row < 9'd224 && since < 9'd300) begin line_tg <= ~line_tg; line_bank <= lc; line_row <= row[7:0]; end
		end
		if (frame_start) begin since <= 9'd0; vin <= 9'd0; end
		if (half) in_vs <= 1'b1;
		else if (full) in_vs <= 1'b0;
	end
end

// 4-line ring: bank lc, 720 pixels (1024 bytes) each, two RAMB16
reg  [7:0]  lbuf [0:4095];
wire [10:0] wx = hc - H_FIRST;
wire        wen = hc >= H_FIRST && hc < H_FIRST + 1440 && !wx[0];
always @(posedge clk)
	if (wen) lbuf[{lc, wx[10:1]}] <= pixel;
always @(posedge rd_clk)
	rd_data <= lbuf[rd_addr];

endmodule
