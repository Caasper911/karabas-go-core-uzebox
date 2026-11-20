// uze_pm_sram.v - the ATmega644 program memory (32K words) in the board SRAM (2M x 16, async): the fetch of the
// CPU, the loader (.uze games, the Bootloader5 ROM) and SPM (variant M2 of docs/PLAN.md).
//
// Run: MA is a register (IOB) loaded with the next fetch address of the CPU every clock, both bytes are read
// (MRD_N = 00), the CPU takes MD at the end of the cycle (pm_rdata straight from the pins).
// Load (the CPU held in reset): one byte per ld_wr, written in 3 clocks (address + data, /WE low, /WE high).
// A .uze file is a 512-byte header and the program: file offset o >= 512 is program byte o - 512; a raw load
// (ld_raw: a ROM of the .kg, Bootloader5 at 0xF000) writes byte ld_addr. Program byte b is word b / 2, the low
// (even) byte on MD[7:0] / MWR_N[0].
// SPM: spm_fill puts r1:r0 into the page buffer (128 words); spm_erase / spm_write write the page (0xFFFF / the
// buffer) word by word, 3 clocks each, with spm_busy high from the strobe on: the CPU is halted meanwhile (it
// fetches from the same SRAM), MA goes back to its fetch address before spm_busy drops.
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uze_pm_sram (
	input             clk,
	input             loading,       // the CPU is in reset: the loader owns the SRAM

	input      [14:0] pm_addr_nx,
	output     [15:0] pm_rdata,

	input             ld_wr,         // one clock per byte
	input             ld_raw,        // a ROM: no .uze header
	input      [31:0] ld_addr,       // file offset
	input      [7:0]  ld_data,
	output            ld_busy,

	input             spm_fill,
	input             spm_erase,
	input             spm_write,
	input      [15:0] spm_z,
	input      [15:0] spm_r,
	output reg        spm_busy,

	output reg [20:0] sram_a,
	input      [15:0] sram_dq_i,
	output reg [15:0] sram_dq_o,
	output reg        sram_dq_oe,
	output reg [1:0]  sram_we_n,
	output reg [1:0]  sram_oe_n
);

assign pm_rdata = sram_dq_i;

// ---------------------------------------------------------------- loader
reg  [1:0]  st;          // 0 idle, 1 address + data, 2 /WE low, 3 /WE high
reg  [14:0] wa;
reg         wl;          // byte lane: 0 low, 1 high
reg  [7:0]  wd;
wire [31:0] po = ld_raw ? ld_addr : ld_addr - 32'd512;
wire        take = ld_wr && (ld_raw || ld_addr >= 32'd512) && po[31:16] == 16'd0;
assign ld_busy = st != 2'd0;

// ---------------------------------------------------------------- SPM
reg  [15:0] pbuf [0:127];
always @(posedge clk)
	if (spm_fill) pbuf[spm_z[7:1]] <= spm_r;
reg  [7:0]  e_page = 8'd0;
reg         e_erase = 1'b0;
reg  [6:0]  e_i = 7'd0;
reg  [1:0]  e_st = 2'd0;          // 0 address, 1 data + /WE low, 2 /WE high, 3 after the last: MA back
reg  [15:0] e_d = 16'd0;
always @(posedge clk) e_d <= e_erase ? 16'hFFFF : pbuf[e_i];

initial begin
	sram_a = 21'd0; sram_dq_o = 16'd0; sram_dq_oe = 1'b0; sram_we_n = 2'b11; sram_oe_n = 2'b00;
	st = 2'd0; wa = 15'd0; wl = 1'b0; wd = 8'd0; spm_busy = 1'b0;
end

always @(posedge clk) begin
	case (st)
		2'd0: if (take) begin wa <= po[15:1]; wl <= po[0]; wd <= ld_data; st <= 2'd1; end
		2'd1: st <= 2'd2;
		2'd2: st <= 2'd3;
		default: st <= 2'd0;
	endcase

	if (!spm_busy && (spm_erase || spm_write)) begin
		spm_busy <= 1'b1; e_page <= spm_z[15:8]; e_erase <= spm_erase; e_i <= 7'd0; e_st <= 2'd0;
	end

	if (loading) begin
		sram_a <= {6'd0, (st == 2'd0 && take) ? po[15:1] : wa};
		sram_oe_n <= 2'b11;
		sram_dq_o <= {wd, wd};
		sram_dq_oe <= st != 2'd0;
		sram_we_n <= (st == 2'd1) ? (wl ? 2'b01 : 2'b10) : 2'b11;
	end else if (spm_busy) begin
		// one word: address; data (e_d of e_i, registered a clock after e_i) and /WE low; /WE high (the data
		// held); after the last word: the data bus off, MA back to the fetch address, spm_busy off
		sram_oe_n <= 2'b11;
		case (e_st)
			2'd0: begin sram_a <= {6'd0, e_page, e_i}; sram_we_n <= 2'b11; e_st <= 2'd1; end
			2'd1: begin sram_dq_o <= e_d; sram_dq_oe <= 1'b1; sram_we_n <= 2'b00; e_st <= 2'd2; end
			2'd2: begin
				sram_we_n <= 2'b11;
				if (e_i == 7'd127) e_st <= 2'd3;
				else begin e_i <= e_i + 7'd1; e_st <= 2'd0; end
			end
			default: begin
				sram_dq_oe <= 1'b0; sram_oe_n <= 2'b00; sram_a <= {6'd0, pm_addr_nx}; spm_busy <= 1'b0;
			end
		endcase
	end else begin
		sram_a <= {6'd0, pm_addr_nx};
		sram_oe_n <= 2'b00;
		sram_we_n <= 2'b11;
		sram_dq_oe <= 1'b0;
	end
end

endmodule
