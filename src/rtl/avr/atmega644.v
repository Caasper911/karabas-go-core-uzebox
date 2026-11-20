// atmega644.v - ATmega644 for the Uzebox: avr_core + avr_io_m644 + 4 KB data SRAM (BRAM).
// The program memory (32K words) is outside: pm_addr is registered, pm_rdata is sampled at the end of
// the cycle (board SRAM with the address in the IOB, or a BRAM fed with pm_addr_nx).
// karabas-go-core-uzebox, GPL-3.0-or-later.

module atmega644 (
	input         clk,
	input         rst,
	input  [14:0] reset_vec,      // word address of the reset (BOOTRST: 0x7800 for the boot section)

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

	input         spi_on,         // 0: SPI as Uzem without an SD card (the lockstep bench)
	output        spi_sck,
	output        spi_mosi,
	input         spi_miso,
	output        spi_start,
	output [7:0]  spi_tx,
	output        spi_done,
	input         spi_ext,
	input  [7:0]  spi_rx_ext,

	output        spm_fill,       // SPM: page buffer word spm_z[7:1] = spm_r
	output        spm_erase,      // SPM: erase page spm_z[15:8]
	output        spm_write,      // SPM: write the page buffer to page spm_z[15:8]
	output [15:0] spm_z,
	output [15:0] spm_r,
	input         spm_busy,       // the program memory works on an erase / write (the CPU halts)

	input         ee_req,         // EEPROM port b (kg_bk_ram)
	input         ee_we,
	input  [10:0] ee_addr,
	input  [7:0]  ee_din,
	output        ee_ack,
	output [7:0]  ee_dout,
	output        ee_cpu_wr,      // the CPU wrote the EEPROM at ee_cpu_addr
	output [10:0] ee_cpu_addr,

	output        insn_start,
	output [15:0] dbg_pc
);

wire [11:0] dm_raddr_nx, dm_waddr;
wire [7:0]  dm_wdata, io_addr, io_wdata, io_bitmask, io_rdata;
wire        dm_we, io_rd, io_wr, irq, irq_ack, wdr, insn_end, halt, spm;
wire [5:0]  irq_vec;
wire        ivsel;
reg  [7:0]  dm_rdata;

avr_core cpu (
	.clk(clk), .rst(rst), .reset_vec(reset_vec), .halt(halt),
	.pm_addr(pm_addr), .pm_addr_nx(pm_addr_nx), .pm_rdata(pm_rdata),
	.dm_raddr_nx(dm_raddr_nx), .dm_rdata(dm_rdata), .dm_we(dm_we), .dm_waddr(dm_waddr), .dm_wdata(dm_wdata),
	.io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr), .io_wdata(io_wdata), .io_bitmask(io_bitmask),
	.io_rdata(io_rdata),
	.irq(irq), .irq_vec(irq_vec), .ivsel(ivsel), .irq_ack(irq_ack),
	.wdr(wdr), .spm(spm), .spm_z(spm_z), .spm_r(spm_r), .insn_start(insn_start), .insn_end(insn_end), .dbg_pc(dbg_pc)
);

avr_io_m644 io (
	.clk(clk), .rst(rst),
	.io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr), .io_wdata(io_wdata), .io_bitmask(io_bitmask),
	.io_rdata(io_rdata),
	.irq(irq), .irq_vec(irq_vec), .ivsel(ivsel), .irq_ack(irq_ack), .wdr(wdr), .insn_end(insn_end), .halt(halt),
	.pina(pina), .pinb(pinb), .pinc(pinc), .pind(pind),
	.porta(porta), .ddra(ddra), .portb(portb), .ddrb(ddrb), .pixel(pixel), .portd(portd), .ddrd(ddrd),
	.ocr2a(ocr2a), .sample(sample),
	.spi_on(spi_on), .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_start(spi_start),
	.spi_tx(spi_tx), .spi_done(spi_done), .spi_ext(spi_ext), .spi_rx_ext(spi_rx_ext),
	.spm(spm), .spm_z(spm_z), .spm_r(spm_r), .spm_fill(spm_fill), .spm_erase(spm_erase), .spm_write(spm_write),
	.spm_busy(spm_busy), .ext_halt(spm_busy),
	.ee_req(ee_req), .ee_we(ee_we), .ee_addr(ee_addr), .ee_din(ee_din), .ee_ack(ee_ack), .ee_dout(ee_dout),
	.ee_cpu_wr(ee_cpu_wr), .ee_cpu_addr(ee_cpu_addr)
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
