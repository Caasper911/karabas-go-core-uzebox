// uze_pads.v - two SNES pads on PORTA of the Uzebox (PA2 latch, PA3 clock, PA0 / PA1 data of pad 1 / 2),
// from the joysticks of the MCU link (JOY_L = pad 1, JOY_R = pad 2) and the USB keyboard (pad 1, the
// keys of Uzem: arrows, Enter Start, Tab Select, A A, S B, X X, Z Y, left / right Shift L / R).
//
// Shift register as a real SNES pad: loaded while the latch is high, shifted on the rising edge of the
// clock; the data line is bit 0 (0 = pressed). The kernel drops the clock, reads, raises it: read k
// gets bit k, as in Uzem. Bits 0..11 B Y Select Start Up Down Left Right A X L R, 12..15 high (a pad,
// not a mouse), then low after 16 bits (a pad is plugged: the kernel reads the line low before the
// latch; Uzem keeps it high, its ControllerTester shows no pad). A port without a pad reads high.
// MCU joystick bits: 0 connected, 1 up, 2 down, 3 left, 4 right, 5 start, 6 A, 7 B, 8 C, 9 X, 10 Y,
// 11 Z, 12 mode; C = R, Z = L, mode = Select. Up + down / left + right together: right / down released
// (as Uzem).
//
// Uzebox keyboard (the ATtiny85 adapter of schematics/Keyboard-Interface in pad port 2, kernel keyboard.c,
// Uzem uzeKbState): a transfer starts with clock low while latch is high; after clock high / latch low, each
// falling clock edge shifts a command bit in from the latch line and a key bit out on the data line of pad 2,
// MSB first; the first byte of a transfer is the next PS/2 set 2 byte of the USB keyboard (0 = none), a
// command byte 01 (KB_SEND_END) ends the transfer. Between transfers port 2 is pad 2.
// kb_mode (OSD Keyboard): 0 Auto, as Uzem: the keys are pad 1 until a program starts a keyboard transfer,
// then keyboard only (until rst: a new game, a reset); 1 Pad: the keys are always pad 1, the adapter answers
// no key; 2 PS/2: always the keyboard.
// SNES mouse (kernel SNES_MOUSE, Uzem SNES mouse mode) from the USB mouse of the MCU (MS_*), in the port of ms_port
// (OSD Mouse: 0 Off, 1 port 1, 2 port 2) once the USB mouse moved or clicked (until rst): 32 bits, line low = 1
// for the kernel: bits 0..7 0, 8 right, 9 left, 10..11 sensitivity, 12..14 0, 15 1 (a mouse), then Y sign (1 up),
// Y 7 bits MSB first, X sign (1 left), X 7 bits. The counts are summed between two latches (taken at the rising
// latch, at most 127 each); sensitivity 0 / 1 / 2 gives counts / 2, x 1, x 2 (Uzem: / 2); a clock pulse while
// the latch is high steps the sensitivity (kernel SetMouseSensitivity), as the real mouse.
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uze_pads (
	input             clk,
	input      [7:0]  porta,
	input      [15:0] joy_l,
	input      [15:0] joy_r,
	input      [55:0] kbd,          // { key6 .. key1, modifiers } (USB HID boot report)
	input             rst,          // the CPU reset: Auto goes back to the pad
	input      [1:0]  kb_mode,      // 0 Auto, 1 Pad, 2 PS/2
	input      [7:0]  ps2_code,     // PS/2 set 2 bytes of the USB keyboard (kg_mcu2 PS2_*, kind 0)
	input             ps2_wr,
	output            kb_on,        // the keys go to the keyboard, not pad 1
	input      [1:0]  ms_port,      // OSD Mouse: 0 Off, 1 port 1, 2 port 2
	input      [7:0]  ms_x,         // USB mouse: signed deltas (y down), buttons (bit 0 left, 1 right)
	input      [7:0]  ms_y,
	input      [7:0]  ms_b,
	input             ms_wr,
	output     [1:0]  data          // PINA[1:0]
);

// ---------------------------------------------------------------- keyboard adapter
localparam KB_STOP = 2'd0, KB_START = 2'd1, KB_READY = 2'd2;
reg  [1:0] kb_st /* verilator public_flat */ = KB_STOP;
reg        kb_seen = 1'b0;      // Auto: a program started a keyboard transfer
reg  [3:0] kb_cnt = 4'd0;
reg  [7:0] kb_out = 8'd0;       // command bits from the latch line
reg  [7:0] kb_in = 8'd0;        // key bits out
reg        kb_bit = 1'b0;
reg        kb_hold = 1'b0;      // the last bit of a transfer: the line stays the key's until the clock rises
reg  [1:0] kb_pa_d = 2'b10;     // clock, latch a clock ago
assign kb_on = kb_mode == 2'd2 || (kb_mode == 2'd0 && kb_seen);

// 16-byte fifo of the set 2 bytes (only while the keys go to the keyboard; a byte with the fifo full is lost)
reg  [7:0] kq [0:15];
reg  [3:0] kq_wp = 4'd0, kq_rp = 4'd0;
reg  [4:0] kq_n = 5'd0;
wire       kq_push = ps2_wr && kb_on && kq_n != 5'd16;
wire       kb_fall = kb_pa_d[1] && !porta[3];
// the start condition is a change into clock low / latch high (Uzem checks it at PORTA writes only: the lines stay
// so after the last bit of KB_SEND_END)
wire       kb_go = porta[3:2] == 2'b01 && kb_pa_d != 2'b01;
wire       kq_pop = kb_st == KB_READY && kb_fall && kb_cnt == 4'd8 && kq_n != 5'd0;
always @(posedge clk) begin
	if (kq_push) begin kq[kq_wp] <= ps2_code; kq_wp <= kq_wp + 4'd1; end
	if (kq_pop) kq_rp <= kq_rp + 4'd1;
	kq_n <= kq_n + {4'd0, kq_push} - {4'd0, kq_pop};
	if (!kb_on) begin kq_rp <= 4'd0; kq_wp <= 4'd0; kq_n <= 5'd0; end
end

always @(posedge clk) begin
	kb_pa_d <= porta[3:2];
	if (porta[3]) kb_hold <= 1'b0;
	if (rst) begin
		kb_st <= KB_STOP; kb_seen <= 1'b0;
	end else case (kb_st)
		KB_STOP:
			if (kb_go) begin kb_st <= KB_START; if (kb_mode == 2'd0) kb_seen <= 1'b1; end
		KB_START:
			if (porta[3:2] == 2'b10) begin kb_st <= KB_READY; kb_cnt <= 4'd8; end
		default:
			if (kb_fall) begin
				// the first bit of a byte: the next key (0 = none; Pad mode: never a key)
				kb_bit <= kb_cnt == 4'd8 ? (kq_n != 5'd0 && kq[kq_rp][7]) : kb_in[7];
				kb_in <= kb_cnt == 4'd8 ? (kq_n != 5'd0 ? {kq[kq_rp][6:0], 1'b0} : 8'd0) : {kb_in[6:0], 1'b0};
				kb_out <= {(kb_cnt == 4'd8 ? 7'd0 : kb_out[6:0]), porta[2]};
				if (kb_cnt == 4'd1) begin
					kb_cnt <= 4'd8;
					if ({kb_out[6:0], porta[2]} == 8'h01) begin kb_st <= KB_STOP; kb_hold <= 1'b1; end   // KB_SEND_END
				end else
					kb_cnt <= kb_cnt - 4'd1;
			end
	endcase
end


function [11:0] from_joy;         // pressed = 1, SNES order
	input [15:0] j;
	begin
		from_joy = {j[8], j[11], j[9], j[6], j[4], j[3], j[2], j[1], j[5], j[12], j[10], j[7]};
	end
endfunction

function key_down;
	input [55:0] k;
	input [7:0]  code;
	begin
		key_down = k[15:8] == code || k[23:16] == code || k[31:24] == code ||
		           k[39:32] == code || k[47:40] == code || k[55:48] == code;
	end
endfunction

wire [11:0] kb_fix = {kbd[5],                    // R: right shift (modifier bit 5)
                      kbd[1],                    // L: left shift (modifier bit 1)
                      key_down(kbd, 8'h1B),      // X: X
                      key_down(kbd, 8'h04),      // A: A
                      key_down(kbd, 8'h4F),      // Right
                      key_down(kbd, 8'h50),      // Left
                      key_down(kbd, 8'h51),      // Down
                      key_down(kbd, 8'h52),      // Up
                      key_down(kbd, 8'h28),      // Start: Enter
                      key_down(kbd, 8'h2B),      // Select: Tab
                      key_down(kbd, 8'h1D),      // Y: Z
                      key_down(kbd, 8'h16)};     // B: S

function [11:0] fix_dirs;          // Up+Down: Down off, Left+Right: Right off
	input [11:0] b;
	begin
		fix_dirs = b;
		if (b[4] && b[5]) fix_dirs[5] = 1'b0;
		if (b[6] && b[7]) fix_dirs[7] = 1'b0;
	end
endfunction

wire [11:0] p1 = fix_dirs(from_joy(joy_l) | (kb_on ? 12'd0 : kb_fix));
wire [11:0] p2 = fix_dirs(from_joy(joy_r));
wire        c1 = 1'b1;            // pad 1 is always there (the keyboard)
wire        c2 = joy_r[0];

// ---------------------------------------------------------------- SNES mouse
reg         ms_seen = 1'b0;      // the USB mouse moved / clicked since rst
reg  signed [11:0] ms_ax = 12'sd0, ms_ay = 12'sd0;   // counts since the last latch
reg  [1:0]  ms_lb = 2'b00;       // buttons
reg  [1:0]  ms_sens = 2'd0;
reg  [15:0] ms_hi = 16'd0;       // the kernel's bits 16..31 (1 = line low): Y sign, Y, X sign, X
reg         lat_d = 1'b0;
reg         clk_d = 1'b0;
wire        lat_rise = porta[2] && !lat_d;
function [7:0] ms_take;            // sign (1 = negative) + 7-bit size of the counts scaled by the sensitivity
	input signed [11:0] a;
	input [1:0] sens;
	reg [11:0] m;
	begin
		m = a[11] ? -a : a;
		m = sens == 2'd0 ? m >> 1 : sens == 2'd1 ? m : m << 1;
		ms_take = {a[11], m > 12'd127 ? 7'd127 : m[6:0]};
	end
endfunction
wire [7:0] ms_tx = ms_take(ms_ax, ms_sens), ms_ty = ms_take(ms_ay, ms_sens);
wire signed [11:0] ms_dx = {{4{ms_x[7]}}, ms_x}, ms_dy = {{4{ms_y[7]}}, ms_y};
always @(posedge clk) begin
	lat_d <= porta[2];
	if (ms_wr) begin
		ms_lb <= ms_b[1:0];
		if (ms_x != 8'd0 || ms_y != 8'd0 || ms_b[1:0] != 2'b00) ms_seen <= 1'b1;
	end
	if (lat_rise) begin
		ms_hi <= {ms_ty, ms_tx};
		ms_ax <= ms_wr ? ms_dx : 12'sd0;
		ms_ay <= ms_wr ? ms_dy : 12'sd0;
	end else if (ms_wr) begin
		ms_ax <= (ms_ax + ms_dx > 12'sd1000) ? 12'sd1000 : (ms_ax + ms_dx < -12'sd1000) ? -12'sd1000 : ms_ax + ms_dx;
		ms_ay <= (ms_ay + ms_dy > 12'sd1000) ? 12'sd1000 : (ms_ay + ms_dy < -12'sd1000) ? -12'sd1000 : ms_ay + ms_dy;
	end
	if (porta[2] && lat_d && clk_d && !porta[3] && kb_st == KB_STOP && !kb_hold) ms_sens <= ms_sens == 2'd2 ? 2'd0 : ms_sens + 2'd1;
	if (rst) begin ms_seen <= 1'b0; ms_sens <= 2'd0; end
end
// the line levels of the 32 bits (bit k = the k-th bit out; low = 1 for the kernel)
function [15:0] rev16;
	input [15:0] v;
	integer i;
	begin for (i = 0; i < 16; i = i + 1) rev16[i] = v[15 - i]; end
endfunction
wire [31:0] ms_word = ~{rev16(ms_hi), 1'b1, 3'b000, ms_sens[1], ms_sens[0], ms_lb[0], ms_lb[1], 8'h00};
wire        m1 = ms_port == 2'd1 && ms_seen;
wire        m2 = ms_port == 2'd2 && ms_seen;

reg [31:0] s1 = 32'hFFFFFFFF, s2 = 32'hFFFFFFFF;
always @(posedge clk) begin
	clk_d <= porta[3];
	if (porta[2]) begin
		s1 <= m1 ? ms_word : c1 ? {16'h0000, 4'hF, ~p1} : 32'hFFFFFFFF;
		s2 <= m2 ? ms_word : c2 ? {16'h0000, 4'hF, ~p2} : 32'hFFFFFFFF;
	end else if (porta[3] && !clk_d) begin
		s1 <= {(c1 || m1) ? 1'b0 : 1'b1, s1[31:1]};      // a device holds the line low after its bits
		s2 <= {(c2 || m2) ? 1'b0 : 1'b1, s2[31:1]};
	end
end
assign data = {(kb_st == KB_READY || kb_hold) ? kb_bit : s2[0], s1[0]};

endmodule
