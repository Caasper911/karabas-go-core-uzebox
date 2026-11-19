// atmega644.v - ATmega644 for the Uzebox: avr_core + avr_io_m644 + 4 KB data SRAM (BRAM).
// The program memory (32K words) is outside: pm_addr is registered, pm_rdata is sampled at the end of
// the cycle (board SRAM with the address in the IOB, or a BRAM fed with pm_addr_nx).
// karabas-go-core-uzebox, GPL-3.0-or-later.

module atmega644 (
	input         clk,
	input         rst,

	output [14:0] pm_addr,
	output [14:0] pm_addr_nx,
	input  [15:0] pm_rdata,

	input  [7:0]  pina,
	input  [7:0]  pinb,
	input  [7:0]  pinc,
	input  [7:0]  pind,
	output [7:0]  porta,
	output [7:0]  ddra,
	output [7:0]  portb,
	output [7:0]  ddrb,
	output [7:0]  pixel,
	output [7:0]  portd,
	output [7:0]  ddrd,

	output [7:0]  ocr2a,
	output        sample,

	output        insn_start,
	output [15:0] dbg_pc
);

wire [11:0] dm_raddr_nx, dm_waddr;
wire [7:0]  dm_wdata, io_addr, io_wdata, io_bitmask, io_rdata;
wire        dm_we, io_rd, io_wr, irq, irq_ack, wdr, insn_end, halt;
wire [5:0]  irq_vec;
reg  [7:0]  dm_rdata;

avr_core cpu (
	.clk(clk), .rst(rst), .halt(halt),
	.pm_addr(pm_addr), .pm_addr_nx(pm_addr_nx), .pm_rdata(pm_rdata),
	.dm_raddr_nx(dm_raddr_nx), .dm_rdata(dm_rdata), .dm_we(dm_we), .dm_waddr(dm_waddr), .dm_wdata(dm_wdata),
	.io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr), .io_wdata(io_wdata), .io_bitmask(io_bitmask),
	.io_rdata(io_rdata),
	.irq(irq), .irq_vec(irq_vec), .irq_ack(irq_ack),
	.wdr(wdr), .insn_start(insn_start), .insn_end(insn_end), .dbg_pc(dbg_pc)
);

avr_io_m644 io (
	.clk(clk), .rst(rst),
	.io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr), .io_wdata(io_wdata), .io_bitmask(io_bitmask),
	.io_rdata(io_rdata),
	.irq(irq), .irq_vec(irq_vec), .irq_ack(irq_ack), .wdr(wdr), .insn_end(insn_end), .halt(halt),
	.pina(pina), .pinb(pinb), .pinc(pinc), .pind(pind),
	.porta(porta), .ddra(ddra), .portb(portb), .ddrb(ddrb), .pixel(pixel), .portd(portd), .ddrd(ddrd),
	.ocr2a(ocr2a), .sample(sample)
);

// data SRAM 4 KB: one write port, one read port (read address of the next cycle)
reg [7:0] sram [0:4095] /* verilator public_flat */;
integer k;
initial for (k = 0; k < 4096; k = k + 1) sram[k] = 8'h00;
always @(posedge clk) begin
	if (dm_we) sram[dm_waddr] <= dm_wdata;
	dm_rdata <= sram[dm_raddr_nx];
end

endmodule
