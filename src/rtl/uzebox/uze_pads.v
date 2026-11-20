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
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uze_pads (
	input             clk,
	input      [7:0]  porta,
	input      [15:0] joy_l,
	input      [15:0] joy_r,
	input      [55:0] kbd,          // { key6 .. key1, modifiers } (USB HID boot report)
	output     [1:0]  data          // PINA[1:0]
);

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

wire [11:0] p1 = fix_dirs(from_joy(joy_l) | kb_fix);
wire [11:0] p2 = fix_dirs(from_joy(joy_r));
wire        c1 = 1'b1;            // pad 1 is always there (the keyboard)
wire        c2 = joy_r[0];

reg [31:0] s1 = 32'hFFFFFFFF, s2 = 32'hFFFFFFFF;
reg        clk_d = 1'b0;
always @(posedge clk) begin
	clk_d <= porta[3];
	if (porta[2]) begin
		s1 <= c1 ? {16'h0000, 4'hF, ~p1} : 32'hFFFFFFFF;
		s2 <= c2 ? {16'h0000, 4'hF, ~p2} : 32'hFFFFFFFF;
	end else if (porta[3] && !clk_d) begin
		s1 <= {c1 ? 1'b0 : 1'b1, s1[31:1]};
		s2 <= {c2 ? 1'b0 : 1'b1, s2[31:1]};
	end
end
assign data = {s2[0], s1[0]};

endmodule
