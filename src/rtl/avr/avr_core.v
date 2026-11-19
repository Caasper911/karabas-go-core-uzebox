// avr_core.v - cycle-exact AVR CPU of the ATmega644 (Uzebox), Verilog-2001 for XST.
//
// Written for karabas-go-core-uzebox from the AVR Instruction Set Manual and the ATmega644 datasheet;
// the cycle behaviour follows Uzem (upstream/uzebox/tools/uzem/avr8.cpp), the reference the Uzebox
// games were tuned on:
//   - every instruction takes the cycles of the manual (16-bit PC device: RCALL/ICALL 3, CALL/RET/RETI 4);
//   - its data / IO access happens in its last cycle, the IO side effects at the end of that cycle;
//   - an interrupt is taken between two instructions and costs 3 cycles (push PC, then the vector);
//   - after SEI (or a write to SREG setting I) two more instructions run before an interrupt.
// Copyright (C) 2026 karabas-go-core-uzebox authors. GPL-3.0-or-later.
//
// Fetch: pm_addr (word address) is a register; the memory returns pm_rdata for it during the cycle and
// the core samples it at the end of the cycle (async SRAM with registered address, or a BRAM fed with
// pm_addr_nx). In the last cycle of every instruction pm_addr holds the address of the next one.
// Data SRAM (4 KB): dm_raddr_nx is the read address of the next cycle (BRAM read port), writes happen at
// the end of the cycle (dm_we). IO: io_addr is the IO index (data address - 0x20); io_rd / io_wr are
// one-cycle strobes; SPL / SPH / SREG live in the core.

module avr_core (
	input             clk,
	input             rst,
	input             halt,          // freeze the CPU (EEPROM access, loader); IO keeps running

	output reg [14:0] pm_addr,
	output     [14:0] pm_addr_nx,
	input      [15:0] pm_rdata,

	output     [11:0] dm_raddr_nx,
	input      [7:0]  dm_rdata,
	output            dm_we,
	output     [11:0] dm_waddr,
	output     [7:0]  dm_wdata,

	output     [7:0]  io_addr,
	output            io_rd,
	output            io_wr,
	output     [7:0]  io_wdata,
	output     [7:0]  io_bitmask,    // SBI / CBI: the bit operated on (0 for other writes)
	input      [7:0]  io_rdata,

	input             irq,
	input      [5:0]  irq_vec,       // word address of the vector
	output            irq_ack,

	output            wdr,           // WDR executed
	output            insn_start,    // first cycle of a program instruction (debug / test bench)
	output            insn_end,      // last cycle of an instruction (incl. a skip) - Uzem's instruction tick
	output     [15:0] dbg_pc
);

// ---------------------------------------------------------------- state
reg [255:0] rf /* verilator public_flat */;
reg [7:0]   sreg /* verilator public_flat */;
reg [15:0]  sp /* verilator public_flat */;
reg [15:0]  pc /* verilator public_flat */;  // address of the instruction in ir
reg [15:0]  ir;
reg [1:0]   cyc;          // cycle within the instruction
reg         irq_slot;     // the current slot is an interrupt entry (cyc > 0)
reg [1:0]   skip;         // 1: squash the next instruction, 2: squash one word
reg [1:0]   ihold;        // instructions to run before an interrupt can be taken
reg         boot;         // first cycle after reset: fetch the reset vector
reg [15:0]  kw;           // second word of JMP / CALL, return address high byte of RET
reg [15:0]  dadr;         // data address of LD / ST (cycle 1)
reg [11:0]  dm_raddr_q;

assign dbg_pc = pc;

function [7:0] rget;
	input [255:0] f;
	input [4:0]   i;
	begin
		rget = f[{i, 3'b000} +: 8];
	end
endfunction

wire [15:0] I  = ir;
wire [4:0]  d5 = I[8:4];
wire [4:0]  r5 = {I[9], I[3:0]};
wire [4:0]  d4 = {1'b1, I[7:4]};
wire [4:0]  r4 = {1'b1, I[3:0]};
wire [4:0]  d3 = {2'b10, I[6:4]};
wire [4:0]  r3 = {2'b10, I[2:0]};
wire [7:0]  K8 = {I[11:8], I[3:0]};
wire [4:0]  dw = {2'b11, I[5:4], 1'b0};
wire [5:0]  Kw = {I[7:6], I[3:0]};
wire [5:0]  q6 = {I[13], I[11:10], I[2:0]};
wire [2:0]  bb = I[2:0];

wire [15:0] X = {rf[27*8 +: 8], rf[26*8 +: 8]};
wire [15:0] Y = {rf[29*8 +: 8], rf[28*8 +: 8]};
wire [15:0] Z = {rf[31*8 +: 8], rf[30*8 +: 8]};

// ---------------------------------------------------------------- decode
wire i_movw   = I[15:8] == 8'h01;
wire i_muls   = I[15:8] == 8'h02;
wire i_mulsu  = I[15:7] == 9'b000000110 && !I[3];
wire i_fmul   = I[15:7] == 9'b000000110 &&  I[3];
wire i_fmuls  = I[15:7] == 9'b000000111 && !I[3];
wire i_fmulsu = I[15:7] == 9'b000000111 &&  I[3];
wire i_cpc    = I[15:10] == 6'b000001;
wire i_sbc    = I[15:10] == 6'b000010;
wire i_add    = I[15:10] == 6'b000011;
wire i_cpse   = I[15:10] == 6'b000100;
wire i_cp     = I[15:10] == 6'b000101;
wire i_sub    = I[15:10] == 6'b000110;
wire i_adc    = I[15:10] == 6'b000111;
wire i_and    = I[15:10] == 6'b001000;
wire i_eor    = I[15:10] == 6'b001001;
wire i_or     = I[15:10] == 6'b001010;
wire i_mov    = I[15:10] == 6'b001011;
wire i_cpi    = I[15:12] == 4'b0011;
wire i_sbci   = I[15:12] == 4'b0100;
wire i_subi   = I[15:12] == 4'b0101;
wire i_ori    = I[15:12] == 4'b0110;
wire i_andi   = I[15:12] == 4'b0111;
wire i_ldi    = I[15:12] == 4'b1110;
wire i_ldd    = I[15:14] == 2'b10 && !I[12] && !I[9];   // LDD Y/Z+q (LD Y / LD Z for q = 0)
wire i_std    = I[15:14] == 2'b10 && !I[12] &&  I[9];
wire g_ld     = I[15:9] == 7'b1001000;
wire g_st     = I[15:9] == 7'b1001001;
wire g_one    = I[15:9] == 7'b1001010;
wire i_lds    = g_ld && I[3:0] == 4'h0;
wire i_ldptr  = g_ld && (I[3:0] == 4'h1 || I[3:0] == 4'h2 || I[3:0] == 4'h9 || I[3:0] == 4'hA ||
                         I[3:0] == 4'hC || I[3:0] == 4'hD || I[3:0] == 4'hE);
wire i_lpmz   = g_ld && (I[3:0] == 4'h4 || I[3:0] == 4'h5);
wire i_pop    = g_ld && I[3:0] == 4'hF;
wire i_sts    = g_st && I[3:0] == 4'h0;
wire i_stptr  = g_st && (I[3:0] == 4'h1 || I[3:0] == 4'h2 || I[3:0] == 4'h9 || I[3:0] == 4'hA ||
                         I[3:0] == 4'hC || I[3:0] == 4'hD || I[3:0] == 4'hE);
wire i_push   = g_st && I[3:0] == 4'hF;
wire i_com    = g_one && I[3:0] == 4'h0;
wire i_neg    = g_one && I[3:0] == 4'h1;
wire i_swap   = g_one && I[3:0] == 4'h2;
wire i_inc    = g_one && I[3:0] == 4'h3;
wire i_asr    = g_one && I[3:0] == 4'h5;
wire i_lsr    = g_one && I[3:0] == 4'h6;
wire i_ror    = g_one && I[3:0] == 4'h7;
wire i_dec    = g_one && I[3:0] == 4'hA;
wire i_jmp    = g_one && I[3:1] == 3'b110;
wire i_call   = g_one && I[3:1] == 3'b111;
wire i_bset   = I[15:7] == 9'b100101000 && I[3:0] == 4'h8;
wire i_bclr   = I[15:7] == 9'b100101001 && I[3:0] == 4'h8;
wire i_ret    = I == 16'h9508;
wire i_reti   = I == 16'h9518;
wire i_wdr    = I == 16'h95A8;
wire i_lpm0   = I == 16'h95C8;
wire i_spm    = I == 16'h95E8;
wire i_ijmp   = I == 16'h9409;
wire i_icall  = I == 16'h9509;
wire i_adiw   = I[15:8] == 8'h96;
wire i_sbiw   = I[15:8] == 8'h97;
wire i_cbi    = I[15:8] == 8'h98;
wire i_sbic   = I[15:8] == 8'h99;
wire i_sbi    = I[15:8] == 8'h9A;
wire i_sbis   = I[15:8] == 8'h9B;
wire i_mul    = I[15:10] == 6'b100111;
wire i_in     = I[15:11] == 5'b10110;
wire i_out    = I[15:11] == 5'b10111;
wire i_rjmp   = I[15:12] == 4'hC;
wire i_rcall  = I[15:12] == 4'hD;
wire i_brbs   = I[15:10] == 6'b111100;
wire i_brbc   = I[15:10] == 6'b111101;
wire i_bld    = I[15:9] == 7'b1111100;
wire i_bst    = I[15:9] == 7'b1111101;
wire i_sbrc   = I[15:9] == 7'b1111110;
wire i_sbrs   = I[15:9] == 7'b1111111;

wire two_word = ((g_ld || g_st) && I[3:0] == 4'h0) || (g_one && I[3:2] == 2'b11);

// ---------------------------------------------------------------- operands
reg  [4:0] ra_i, rb_i;
always @* begin
	ra_i = d5;
	rb_i = r5;
	if (i_cpi | i_sbci | i_subi | i_ori | i_andi | i_ldi | i_muls) begin ra_i = d4; rb_i = r4; end
	if (i_mulsu | i_fmul | i_fmuls | i_fmulsu) begin ra_i = d3; rb_i = r3; end
	if (i_adiw | i_sbiw) begin ra_i = dw; rb_i = dw | 5'd1; end
	if (i_movw) begin ra_i = {I[3:0], 1'b0}; rb_i = {I[3:0], 1'b1}; end
end
wire [7:0] A = rget(rf, ra_i);
wire [7:0] B = rget(rf, rb_i);
wire [7:0] Rd8 = rget(rf, d5);       // Rd of LD / ST / PUSH / OUT / one-operand / bit ops

// ---------------------------------------------------------------- ALU (cycle 0)
wire       Cf = sreg[0];
wire       Zf = sreg[1];
wire [7:0] opb   = (i_cpi | i_sbci | i_subi | i_ori | i_andi) ? K8 : B;
wire       use_c = i_adc | i_sbc | i_sbci | i_cpc;
wire [7:0] sum   = A + opb + (use_c & Cf);
wire [7:0] dif   = A - opb - (use_c & Cf);
wire [7:0] cy_a  = (A & opb) | (opb & ~sum) | (~sum & A);
wire [7:0] bw_s  = (~A & opb) | (opb & dif) | (dif & ~A);
wire       v_add = (A[7] & opb[7] & ~sum[7]) | (~A[7] & ~opb[7] & sum[7]);
wire       v_sub = (A[7] & ~opb[7] & ~dif[7]) | (~A[7] & opb[7] & dif[7]);
wire [7:0] negr  = 8'd0 - Rd8;
wire [7:0] bw_n  = (Rd8) | (Rd8 & negr) | (negr);      // borrows of 0 - Rd
wire [15:0] w16  = {B, A};
wire [15:0] adw  = w16 + {10'd0, Kw};
wire [15:0] sbw  = w16 - {10'd0, Kw};
// multiplier: 9-bit signed operands
wire        ms_a = (i_muls | i_mulsu | i_fmuls | i_fmulsu) & A[7];
wire        ms_b = (i_muls | i_fmuls) & B[7];
wire signed [8:0]  m_a = {ms_a, A};
wire signed [8:0]  m_b = {ms_b, B};
wire signed [17:0] m_p = m_a * m_b;
wire [15:0] mp16 = m_p[15:0];
wire        m_frac = i_fmul | i_fmuls | i_fmulsu;
wire [15:0] mres = m_frac ? {mp16[14:0], 1'b0} : mp16;

// ---------------------------------------------------------------- data address of LD / ST
reg  [15:0] ptr;          // pointer value used as the address
reg  [15:0] ptr_upd;      // new pointer value
reg  [4:0]  ptr_reg;      // low register of the pointer
reg         ptr_wr;
always @* begin
	ptr = Z; ptr_reg = 5'd30; ptr_upd = Z; ptr_wr = 1'b0;
	case (I[3:2])
		2'b11: begin ptr = X; ptr_reg = 5'd26; end
		2'b10: begin ptr = Y; ptr_reg = 5'd28; end
		default: begin ptr = Z; ptr_reg = 5'd30; end
	endcase
	if (I[3:0] == 4'h1 || I[3:0] == 4'h9 || I[3:0] == 4'hD) begin   // post increment
		ptr_upd = ptr + 16'd1; ptr_wr = 1'b1;
	end
	if (I[3:0] == 4'h2 || I[3:0] == 4'hA || I[3:0] == 4'hE) begin   // pre decrement
		ptr = ptr - 16'd1; ptr_upd = ptr; ptr_wr = 1'b1;
	end
end
wire [15:0] yz_q = (I[3] ? Y : Z) + {10'd0, q6};

function [11:0] sram_idx;
	input [15:0] a;
	begin
		sram_idx = a[11:0] - 12'h100;
	end
endfunction

// data space read in cycle 1 (registers / IO / SRAM)
wire        d_is_reg = dadr[15:5] == 11'd0;
wire        d_is_io  = !d_is_reg && dadr[15:8] == 8'd0;
wire [7:0]  d_ioa    = dadr[7:0] - 8'h20;

// ---------------------------------------------------------------- IO access of the cycle
reg  [7:0] ioa;
reg        io_rd_c, io_wr_c;
reg  [7:0] io_wd_c, io_bm_c;
wire       ioa_core = ioa == 8'h3D || ioa == 8'h3E || ioa == 8'h3F;
wire [7:0] io_in = ioa == 8'h3D ? sp[7:0] : ioa == 8'h3E ? sp[15:8] : ioa == 8'h3F ? sreg : io_rdata;

// ---------------------------------------------------------------- the cycle
wire squash   = skip != 2'd0;
wire take_irq = !boot && cyc == 2'd0 && !squash && sreg[7] && irq && ihold == 2'd0;
wire in_irq   = cyc == 2'd0 ? take_irq : irq_slot;

reg         last;
reg  [14:0] fa_nx;
reg         fa_set;
reg         wa_en, wb_en;
reg  [4:0]  wa_i, wb_i;
reg  [7:0]  wa_d, wb_d;
reg  [7:0]  sreg_nx;
reg  [15:0] sp_nx;
reg  [11:0] dm_ra;
reg         dm_we_c;
reg  [11:0] dm_wa;
reg  [7:0]  dm_wd;
reg  [1:0]  skip_nx;
reg  [1:0]  ihold_nx;
reg  [15:0] kw_nx;
reg  [15:0] dadr_nx;
reg         ack_c, wdr_c;

wire [15:0] pc1 = pc + 16'd1;
wire [15:0] pc2 = pc + 16'd2;

task wr_a; input [4:0] i; input [7:0] d; begin wa_en = 1'b1; wa_i = i; wa_d = d; end endtask
task wr_b; input [4:0] i; input [7:0] d; begin wb_en = 1'b1; wb_i = i; wb_d = d; end endtask
task jump_to; input [15:0] t; begin fa_set = 1'b1; fa_nx = t[14:0]; end endtask
task io_read; input [7:0] a; begin ioa = a; io_rd_c = 1'b1; end endtask
task io_write; input [7:0] a; input [7:0] d; begin ioa = a; io_wr_c = 1'b1; io_wd_c = d; end endtask
task push; input [7:0] d; begin dm_we_c = 1'b1; dm_wa = sram_idx(sp_nx); dm_wd = d; sp_nx = sp_nx - 16'd1; end endtask

always @* begin
	last = 1'b0; fa_set = 1'b0; fa_nx = pm_addr;
	wa_en = 1'b0; wa_i = 5'd0; wa_d = 8'd0;
	wb_en = 1'b0; wb_i = 5'd0; wb_d = 8'd0;
	sreg_nx = sreg; sp_nx = sp;
	dm_ra = dm_raddr_q; dm_we_c = 1'b0; dm_wa = 12'd0; dm_wd = 8'd0;
	ioa = 8'd0; io_rd_c = 1'b0; io_wr_c = 1'b0; io_wd_c = 8'd0; io_bm_c = 8'd0;
	skip_nx = skip; ihold_nx = ihold; kw_nx = kw; dadr_nx = dadr;
	ack_c = 1'b0; wdr_c = 1'b0;

	if (boot) begin
		last = 1'b1;
	end else if (in_irq) begin
		// interrupt entry: push PC (low byte first), then fetch the vector
		case (cyc)
			2'd0: begin ack_c = 1'b1; sreg_nx[7] = 1'b0; push(pc[7:0]); kw_nx = {10'd0, irq_vec}; end
			2'd1: begin push(pc[15:8]); jump_to(kw); end
			default: last = 1'b1;
		endcase
	end else if (squash) begin
		last = 1'b1;
		skip_nx = (skip == 2'd1 && two_word) ? 2'd2 : 2'd0;
	end else begin
		if (cyc == 2'd0 && ihold != 2'd0) ihold_nx = ihold - 2'd1;

		// ---------------- one-cycle ALU and moves
		if (i_add | i_adc) begin
			last = 1'b1; wr_a(d5, sum);
			sreg_nx[5] = cy_a[3]; sreg_nx[0] = cy_a[7]; sreg_nx[3] = v_add; sreg_nx[2] = sum[7];
			sreg_nx[4] = sum[7] ^ v_add; sreg_nx[1] = sum == 8'd0;
		end
		if (i_sub | i_sbc | i_subi | i_sbci | i_cp | i_cpc | i_cpi) begin
			last = 1'b1;
			if (!(i_cp | i_cpc | i_cpi)) wr_a(ra_i, dif);
			sreg_nx[5] = bw_s[3]; sreg_nx[0] = bw_s[7]; sreg_nx[3] = v_sub; sreg_nx[2] = dif[7];
			sreg_nx[4] = dif[7] ^ v_sub;
			sreg_nx[1] = (i_sbc | i_sbci | i_cpc) ? (Zf & (dif == 8'd0)) : (dif == 8'd0);
		end
		if (i_and | i_andi | i_or | i_ori | i_eor) begin
			last = 1'b1;
			wr_a(ra_i, (i_and | i_andi) ? (A & opb) : (i_eor ? (A ^ opb) : (A | opb)));
			sreg_nx[3] = 1'b0;
			sreg_nx[2] = wa_d[7]; sreg_nx[4] = wa_d[7]; sreg_nx[1] = wa_d == 8'd0;
		end
		if (i_mov) begin last = 1'b1; wr_a(d5, B); end
		if (i_ldi) begin last = 1'b1; wr_a(d4, K8); end
		if (i_movw) begin last = 1'b1; wr_a({I[7:4], 1'b0}, A); wr_b({I[7:4], 1'b1}, B); end
		if (i_com) begin
			last = 1'b1; wr_a(d5, ~Rd8);
			sreg_nx[0] = 1'b1; sreg_nx[3] = 1'b0; sreg_nx[2] = ~Rd8[7]; sreg_nx[4] = ~Rd8[7];
			sreg_nx[1] = Rd8 == 8'hFF;
		end
		if (i_neg) begin
			last = 1'b1; wr_a(d5, negr);
			sreg_nx[5] = bw_n[3]; sreg_nx[0] = bw_n[7]; sreg_nx[3] = negr == 8'h80; sreg_nx[2] = negr[7];
			sreg_nx[4] = negr[7] ^ (negr == 8'h80); sreg_nx[1] = negr == 8'd0;
		end
		if (i_swap) begin last = 1'b1; wr_a(d5, {Rd8[3:0], Rd8[7:4]}); end
		if (i_inc | i_dec) begin
			last = 1'b1; wr_a(d5, i_inc ? Rd8 + 8'd1 : Rd8 - 8'd1);
			sreg_nx[3] = i_inc ? (wa_d == 8'h80) : (wa_d == 8'h7F);
			sreg_nx[2] = wa_d[7]; sreg_nx[4] = wa_d[7] ^ sreg_nx[3]; sreg_nx[1] = wa_d == 8'd0;
		end
		if (i_asr | i_lsr | i_ror) begin
			last = 1'b1;
			wr_a(d5, {i_asr ? Rd8[7] : (i_ror ? Cf : 1'b0), Rd8[7:1]});
			sreg_nx[0] = Rd8[0]; sreg_nx[2] = wa_d[7]; sreg_nx[3] = wa_d[7] ^ Rd8[0];
			sreg_nx[4] = Rd8[0]; // S = N ^ V = C
			sreg_nx[1] = wa_d == 8'd0;
		end
		if (i_bset) begin
			last = 1'b1; sreg_nx[I[6:4]] = 1'b1;
			if (I[6:4] == 3'd7 && !sreg[7]) ihold_nx = 2'd2;
		end
		if (i_bclr) begin last = 1'b1; sreg_nx[I[6:4]] = 1'b0; end
		if (i_bst) begin last = 1'b1; sreg_nx[6] = Rd8[bb]; end
		if (i_bld) begin
			last = 1'b1; wr_a(d5, Rd8);
			wa_d[bb] = sreg[6];
		end
		if (I == 16'h0000 || I == 16'h9588 || I == 16'h9598) last = 1'b1;    // NOP, SLEEP, BREAK
		if (i_wdr) begin last = 1'b1; wdr_c = 1'b1; end

		// ---------------- IN / OUT
		if (i_in) begin
			last = 1'b1; io_read({2'b00, I[10:9], I[3:0]}); wr_a(d5, io_in);
		end
		if (i_out) begin
			last = 1'b1; io_write({2'b00, I[10:9], I[3:0]}, Rd8);
		end

		// ---------------- branches and skips
		if (i_brbs | i_brbc) begin
			if (cyc == 2'd0) begin
				if (sreg[I[2:0]] == i_brbs) jump_to(pc1 + {{9{I[9]}}, I[9:3]});
				else last = 1'b1;
			end else last = 1'b1;
		end
		if (i_cpse | i_sbrc | i_sbrs) begin
			last = 1'b1;
			if (i_cpse ? (Rd8 == B) : (Rd8[bb] == i_sbrs)) skip_nx = 2'd1;
		end
		if (i_sbic | i_sbis) begin
			last = 1'b1; io_read({3'b000, I[7:3]});
			if (io_in[bb] == i_sbis) skip_nx = 2'd1;
		end
		if (i_rjmp | i_ijmp) begin
			if (cyc == 2'd0) jump_to(i_ijmp ? Z : pc1 + {{4{I[11]}}, I[11:0]});
			else last = 1'b1;
		end
		if (i_jmp) begin
			case (cyc)
				2'd0: kw_nx = pm_rdata;
				2'd1: jump_to(kw);
				default: last = 1'b1;
			endcase
		end
		if (i_rcall | i_icall) begin
			case (cyc)
				2'd0: push(pc1[7:0]);
				2'd1: begin push(pc1[15:8]); jump_to(i_icall ? Z : pc1 + {{4{I[11]}}, I[11:0]}); end
				default: last = 1'b1;
			endcase
		end
		if (i_call) begin
			case (cyc)
				2'd0: kw_nx = pm_rdata;
				2'd1: push(pc2[7:0]);
				2'd2: begin push(pc2[15:8]); jump_to(kw); end
				default: last = 1'b1;
			endcase
		end
		if (i_ret | i_reti) begin
			case (cyc)
				2'd0: dm_ra = sram_idx(sp + 16'd1);
				2'd1: begin kw_nx[15:8] = dm_rdata; dm_ra = sram_idx(sp + 16'd2); end
				2'd2: begin jump_to({kw[15:8], dm_rdata}); sp_nx = sp + 16'd2; end
				default: begin last = 1'b1; if (i_reti) sreg_nx[7] = 1'b1; end
			endcase
		end

		// ---------------- two-cycle word ops
		if (i_adiw | i_sbiw) begin
			if (cyc == 2'd0) begin
				wr_a(dw, i_adiw ? adw[7:0] : sbw[7:0]); wr_b(dw | 5'd1, i_adiw ? adw[15:8] : sbw[15:8]);
				if (i_adiw) begin
					sreg_nx[3] = ~w16[15] & adw[15]; sreg_nx[0] = ~adw[15] & w16[15];
					sreg_nx[2] = adw[15]; sreg_nx[1] = adw == 16'd0;
				end else begin
					sreg_nx[3] = w16[15] & ~sbw[15]; sreg_nx[0] = sbw[15] & ~w16[15];
					sreg_nx[2] = sbw[15]; sreg_nx[1] = sbw == 16'd0;
				end
				sreg_nx[4] = sreg_nx[2] ^ sreg_nx[3];
			end else last = 1'b1;
		end
		if (i_mul | i_muls | i_mulsu | i_fmul | i_fmuls | i_fmulsu) begin
			if (cyc == 2'd0) begin
				wr_a(5'd0, mres[7:0]); wr_b(5'd1, mres[15:8]);
				sreg_nx[0] = mp16[15]; sreg_nx[1] = mp16 == 16'd0;
			end else last = 1'b1;
		end

		// ---------------- SBI / CBI (read-modify-write in the last cycle)
		if (i_sbi | i_cbi) begin
			if (cyc == 2'd1) begin
				last = 1'b1; io_read({3'b000, I[7:3]});
				io_wr_c = 1'b1; io_bm_c = 8'd1 << bb;
				io_wd_c = i_sbi ? (io_in | io_bm_c) : (io_in & ~io_bm_c);
			end
		end

		// ---------------- loads / stores
		if (i_ldptr | i_ldd | i_lds | i_stptr | i_std | i_sts) begin
			if (cyc == 2'd0) begin
				if (i_lds | i_sts) begin
					dadr_nx = pm_rdata; fa_set = 1'b1; fa_nx = pc2[14:0];
				end else if (i_ldd | i_std) begin
					dadr_nx = yz_q;
				end else begin
					dadr_nx = ptr;
					if (ptr_wr) begin wr_a(ptr_reg, ptr_upd[7:0]); wr_b(ptr_reg | 5'd1, ptr_upd[15:8]); end
				end
				dm_ra = sram_idx(dadr_nx);
			end else begin
				last = 1'b1;
				if (i_ldptr | i_ldd | i_lds) begin
					if (d_is_reg) wr_a(d5, rget(rf, dadr[4:0]));
					else if (d_is_io) begin io_read(d_ioa); wr_a(d5, io_in); end
					else wr_a(d5, dm_rdata);
				end else begin
					if (d_is_reg) wr_a(dadr[4:0], Rd8);
					else if (d_is_io) io_write(d_ioa, Rd8);
					else begin dm_we_c = 1'b1; dm_wa = sram_idx(dadr); dm_wd = Rd8; end
				end
			end
		end
		if (i_push) begin
			if (cyc == 2'd1) begin last = 1'b1; push(Rd8); end
		end
		if (i_pop) begin
			if (cyc == 2'd0) dm_ra = sram_idx(sp + 16'd1);
			else begin last = 1'b1; wr_a(d5, dm_rdata); sp_nx = sp + 16'd1; end
		end

		// ---------------- LPM (3 cycles), SPM (4 cycles, not implemented yet: Ф2)
		if (i_lpmz | i_lpm0) begin
			case (cyc)
				2'd0: jump_to({1'b0, Z[15:1]});
				2'd1: begin
					wr_a(i_lpm0 ? 5'd0 : d5, Z[0] ? pm_rdata[15:8] : pm_rdata[7:0]);
					jump_to(pc1);
				end
				default: begin
					last = 1'b1;
					if (i_lpmz && I[0]) begin wr_a(5'd30, Z[7:0] + 8'd1); wr_b(5'd31, Z[15:8] + (Z[7:0] == 8'hFF)); end
				end
			endcase
		end
		if (i_spm) begin
			if (cyc == 2'd3) last = 1'b1;
		end

		// unknown opcodes run as a one-cycle NOP
		if (!(i_add | i_adc | i_sub | i_sbc | i_subi | i_sbci | i_cp | i_cpc | i_cpi | i_and | i_andi | i_or |
		      i_ori | i_eor | i_mov | i_ldi | i_movw | i_com | i_neg | i_swap | i_inc | i_dec | i_asr | i_lsr |
		      i_ror | i_bset | i_bclr | i_bst | i_bld | i_in | i_out | i_brbs | i_brbc | i_cpse | i_sbrc |
		      i_sbrs | i_sbic | i_sbis | i_rjmp | i_ijmp | i_jmp | i_rcall | i_icall | i_call | i_ret | i_reti |
		      i_adiw | i_sbiw | i_mul | i_muls | i_mulsu | i_fmul | i_fmuls | i_fmulsu | i_sbi | i_cbi |
		      i_ldptr | i_ldd | i_lds | i_stptr | i_std | i_sts | i_push | i_pop | i_lpmz | i_lpm0 | i_spm |
		      i_wdr))
			last = 1'b1;
	end

	// writes to SPL / SPH / SREG through the IO space
	if (io_wr_c && ioa_core) begin
		if (ioa == 8'h3D) sp_nx[7:0] = io_wd_c;
		if (ioa == 8'h3E) sp_nx[15:8] = io_wd_c;
		if (ioa == 8'h3F) begin
			sreg_nx = io_wd_c;
			if (io_wd_c[7] && !sreg[7]) ihold_nx = 2'd2;
		end
	end
end

// ---------------------------------------------------------------- outputs
assign pm_addr_nx  = halt ? pm_addr : (last ? pm_addr + 15'd1 : (fa_set ? fa_nx : pm_addr));
assign dm_raddr_nx = halt ? dm_raddr_q : dm_ra;
assign dm_we       = dm_we_c & !halt;
assign dm_waddr    = dm_wa;
assign dm_wdata    = dm_wd;
assign io_addr     = ioa;
assign io_rd       = io_rd_c & !halt & !ioa_core;
assign io_wr       = io_wr_c & !halt & !ioa_core;
assign io_wdata    = io_wd_c;
assign io_bitmask  = io_bm_c;
assign irq_ack     = ack_c & !halt;
assign wdr         = wdr_c & !halt;
assign insn_start  = !halt && !boot && cyc == 2'd0 && !squash && !take_irq;
assign insn_end    = !halt && last && !in_irq && !boot && skip_nx == 2'd0;

// ---------------------------------------------------------------- registers
integer i;
always @(posedge clk) begin
	if (rst) begin
		pm_addr <= 15'd0;
		pc <= 16'd0; ir <= 16'd0; cyc <= 2'd0; irq_slot <= 1'b0; skip <= 2'd0; ihold <= 2'd0;
		boot <= 1'b1; sreg <= 8'd0; sp <= 16'd0; kw <= 16'd0; dadr <= 16'd0; dm_raddr_q <= 12'd0;
	end else if (!halt) begin
		pm_addr <= pm_addr_nx;
		dm_raddr_q <= dm_ra;
		sreg <= sreg_nx; sp <= sp_nx; skip <= skip_nx; ihold <= ihold_nx; kw <= kw_nx; dadr <= dadr_nx;
		if (last) begin
			ir <= pm_rdata; pc <= {1'b0, pm_addr}; cyc <= 2'd0; irq_slot <= 1'b0; boot <= 1'b0;
		end else begin
			cyc <= cyc + 2'd1;
			if (cyc == 2'd0) irq_slot <= take_irq;
		end
		for (i = 0; i < 32; i = i + 1) begin
			if (wa_en && wa_i == i) rf[i*8 +: 8] <= wa_d;
			else if (wb_en && wb_i == i) rf[i*8 +: 8] <= wb_d;
		end
	end
end

endmodule
