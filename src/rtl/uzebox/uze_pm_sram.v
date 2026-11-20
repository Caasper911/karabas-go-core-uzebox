// uze_pm_sram.v - the ATmega644 program memory (32K words) in the board SRAM (2M x 16, async) and the
// .uze loader (variant M2 of docs/PLAN.md).
//
// Run: MA is a register (IOB) loaded with the next fetch address of the CPU every clock, both bytes are
// read (MRD_N = 00), the CPU takes MD at the end of the cycle (pm_rdata straight from the pins).
// Load (the CPU held in reset): one byte per ld_wr, written in 3 clocks (address + data, /WE low, /WE
// high). A .uze file is a 512-byte header and the program: file offset o >= 512 is program byte o - 512,
// word (o - 512) / 2, low byte (even) on MD[7:0] / MWR_N[0].
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uze_pm_sram (
	input             clk,
	input             loading,       // the CPU is in reset: the loader owns the SRAM

	input      [14:0] pm_addr_nx,
	output     [15:0] pm_rdata,

	input             ld_wr,         // one clock per byte
	input      [31:0] ld_addr,       // file offset
	input      [7:0]  ld_data,
	output            ld_busy,

	output reg [20:0] sram_a,
	input      [15:0] sram_dq_i,
	output reg [15:0] sram_dq_o,
	output reg        sram_dq_oe,
	output reg [1:0]  sram_we_n,
	output reg [1:0]  sram_oe_n
);

assign pm_rdata = sram_dq_i;

reg  [1:0]  st;          // 0 idle, 1 address + data, 2 /WE low, 3 /WE high
reg  [14:0] wa;
reg         wl;          // byte lane: 0 low, 1 high
reg  [7:0]  wd;
wire [31:0] po = ld_addr - 32'd512;
wire        take = ld_wr && ld_addr >= 32'd512 && po[31:16] == 16'd0;
assign ld_busy = st != 2'd0;

initial begin
	sram_a = 21'd0; sram_dq_o = 16'd0; sram_dq_oe = 1'b0; sram_we_n = 2'b11; sram_oe_n = 2'b00;
	st = 2'd0; wa = 15'd0; wl = 1'b0; wd = 8'd0;
end

always @(posedge clk) begin
	case (st)
		2'd0: if (take) begin wa <= po[15:1]; wl <= po[0]; wd <= ld_data; st <= 2'd1; end
		2'd1: st <= 2'd2;
		2'd2: st <= 2'd3;
		default: st <= 2'd0;
	endcase

	if (!loading) begin
		sram_a <= {6'd0, pm_addr_nx};
		sram_oe_n <= 2'b00;
		sram_we_n <= 2'b11;
		sram_dq_oe <= 1'b0;
	end else begin
		sram_a <= {6'd0, (st == 2'd0 && take) ? po[15:1] : wa};
		sram_oe_n <= 2'b11;
		sram_dq_o <= {wd, wd};
		sram_dq_oe <= st != 2'd0;
		sram_we_n <= (st == 2'd1) ? (wl ? 2'b01 : 2'b10) : 2'b11;
	end
end

endmodule
