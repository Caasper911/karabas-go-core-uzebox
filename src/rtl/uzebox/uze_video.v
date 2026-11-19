// uze_video.v - the Uzebox picture (PORTC) doubled to 720 x 480 in the CPU clock (variant V3 of
// docs/PLAN.md): one output pixel per two CPU cycles (the first of the pair, as Uzem draws),
// 910 x 524 clocks, 31.6 kHz, 60.3 Hz at 28.75 MHz.
//
// The output timing runs on its own and never jumps (user 2026-11-20: a genlock that realigned the
// output to the sync of the game made the monitor lose sync, Arkanoid every frame): lines of 910
// clocks always; frames of 524 lines, 523 or 525 while the picture is pulled into place.
//
// Input: hc / vin count the input line (1820 cycles) and frame (262 lines) and run free; they lock to
// the sync of the kernel (PB0): a rising edge 1820 cycles after the last one starts a line (hc = 0);
// edges 910 cycles apart are the half lines of the vertical sync: the first one of a frame makes the
// current line number 0. Picture pixel x of an input line = the cycle H_FIRST + 2x after its start
// (the window of Uzem), x = 0..719, written into bank lc of a 4-line ring (lc counts input lines).
// Output: at the start of each output line the last complete input line is taken (bank lc - 1, its
// picture row vin - 1 - V_FIRST); a row is shown on the two output lines that start during the next
// input line. Vertical lock: the output line that first shows row 0 should be O_PIC; if it is later,
// this frame gets 525 lines (the picture moves up one line per frame), earlier 523, else 524. The
// length is set at that line, in the same frame (one frame later it overshot: 26112003 hunted, period 3).
// Output timing (clocks): line 910: hsync 0..61, active 148..867; frame: vsync 0..5, active 36..515,
// picture lines 52..499 once locked. hs / vs / de high active.
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
	output            frame_start,    // one cycle at input line 0 (debug, test bench)
	output            locked          // the picture is in place (debug, test bench)
);

localparam H_TOTAL = 1820, H_HALF = 910;
localparam O_HTOTAL = 910, O_VTOTAL = 524, O_ACT = 36, O_PIC = 52;
localparam HS_END = 62, HA = 148;

// ---------------------------------------------------------------- input
reg [10:0] hc /* verilator public_flat */ = 11'd0;
reg [8:0]  vin /* verilator public_flat */ = 9'd0;
reg [1:0]  lc = 2'd0;            // input lines mod 4: the bank being written
reg [11:0] per = 12'd0;          // cycles since the last rise of PB0
reg        sync_d = 1'b0;
reg        in_vs = 1'b0;         // inside the half lines of the vertical sync
wire       rise = sync & ~sync_d;
wire       full = rise && per == H_TOTAL - 1;
wire       half = rise && per == H_HALF - 1;
wire       wrap = hc == H_TOTAL - 1;
wire       realign = full && hc != 11'd0;
wire       line_end = realign || wrap;
assign frame_start = half && !in_vs;

always @(posedge clk) begin
	sync_d <= sync;
	if (rise) per <= 12'd0;
	else if (per != 12'hFFF) per <= per + 12'd1;
	if (rst) begin
		hc <= 11'd0; vin <= 9'd0; in_vs <= 1'b0;
	end else begin
		hc <= realign ? 11'd1 : wrap ? 11'd0 : hc + 11'd1;
		if (line_end) begin
			vin <= (vin == 9'd261) ? 9'd0 : vin + 9'd1;
			lc <= lc + 2'd1;
		end
		if (half && !in_vs) vin <= 9'd0;                // first half line: this is line 0
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

// ---------------------------------------------------------------- output timing (free running)
reg  [9:0] ho = 10'd0;
reg  [9:0] vo = 10'd0;
reg  [9:0] vtot = O_VTOTAL;      // lines of the current frame: 523, 524, 525
reg  [1:0] rbank = 2'd0;
reg  [8:0] rrow = 9'h1FF;        // picture row of the current output line (>= 224: none)
reg  [8:0] prow = 9'h1FF;
reg        lock_r /* verilator public_flat */ = 1'b0;
wire       hend = ho == O_HTOTAL - 1;
wire       vend = vo >= vtot - 10'd1;     // >=: a frame shortened at its last line still ends
wire [8:0] vprev = (vin == 9'd0) ? 9'd261 : vin - 9'd1;
assign locked = lock_r;

always @(posedge clk) begin
	ho <= hend ? 10'd0 : ho + 10'd1;
	if (hend) begin
		vo <= vend ? 10'd0 : vo + 10'd1;
		if (vend) vtot <= O_VTOTAL;                       // 524 unless row 0 is seen off place
	end
	if (ho == 10'd0) begin
		// the last complete input line; vin is the line being written (lc in step with it)
		rbank <= lc - 2'd1;
		rrow <= vprev - V_FIRST;
		prow <= rrow;
		if (vprev - V_FIRST == 9'd0 && rrow != 9'd0) begin      // the first line showing row 0
			if (vo == O_PIC) lock_r <= 1'b1;
			else begin
				lock_r <= 1'b0;
				vtot <= (vo > O_PIC && vo < O_PIC + 262) ? O_VTOTAL + 1 : O_VTOTAL - 1;
			end
		end
	end
end

// ---------------------------------------------------------------- output pixels
wire        act_h = ho >= HA && ho < HA + 720;
wire        act_v = vo >= O_ACT && vo < O_ACT + 480;
wire        pic = rrow < 9'd224;
wire [9:0]  rx = ho - HA;

reg  [7:0] px;
reg        hs1, vs1, de1, pic1;
always @(posedge clk) begin
	px <= lbuf[{rbank, rx}];
	hs1 <= ho < HS_END;
	vs1 <= vo < 10'd6;
	de1 <= act_h && act_v;
	pic1 <= act_h && act_v && pic;
	hs <= hs1; vs <= vs1; de <= de1;
	rgb <= pic1 ? {px[2:0], px[2:0], px[2:1], px[5:3], px[5:3], px[5:4], px[7:6], px[7:6], px[7:6], px[7:6]}
	            : 24'd0;
end

endmodule
