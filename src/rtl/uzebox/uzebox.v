// uzebox.v - the Uzebox console without the board: ATmega644 (program memory in the board SRAM), the
// .uze loader, two SNES pads, the video (uze_video: lines of the game -> uze_fb: frame buffer in the board
// SDRAM -> CEA 720 x 480p in clk_vid) and the 8-bit sound.
//
// boot = 0 (Game): the CPU starts at 0 once a game is loaded (an FL load of a .uze); boot = 1 (Loader):
// Bootloader5 (a raw ROM load at 0xF000 from the .kg) starts at 0x7800 (BOOTRST) once it is loaded and flashes
// the games from the SD card by SPM. The CPU is held in reset while a load runs, while the EEPROM file is read
// (kg_bk_ram: <game>.sav next to the .uze, slot 2 of the file mounter) and while `reset` is high (OSD Reset). Sound: the OCR2A sample the kernel writes once per line
// (15.7 kHz), unsigned 8 bit, as `audio` (two's complement 16 bit, an eighth of full scale, clk).
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uzebox #(
	parameter V_FIRST = 30
) (
	input             clk,            // CPU clock (28.75 MHz)
	input             clk_sdr,        // SDRAM clock (71.875 MHz)
	input             areset_sdr,     // clk_sdr domain
	input             clk_vid,        // video clock (27 MHz)
	input             areset,         // clk domain
	input             reset,          // OSD reset, clk domain

	input             boot,           // 0 the game from the OSD, 1 Bootloader5
	input             ld_raw,         // the load is a ROM (Bootloader5 at its address), not a .uze
	input             ld_start,       // a new file (FL item of the game) / ROM
	input             ld_active,
	input             ld_end,
	input             ld_wr,
	input      [31:0] ld_addr,
	input      [7:0]  ld_data,

	input      [15:0] joy_l,
	input      [15:0] joy_r,
	input      [55:0] kbd,
	input      [1:0]  kb_mode,        // OSD Keyboard: 0 Auto, 1 Pad, 2 PS/2 (uze_pads)
	input      [7:0]  ps2_code,       // PS/2 set 2 bytes of the USB keyboard
	input             ps2_wr,
	input             spiram_big,     // OSD SPI RAM: 1 8 MB (PSRAM), 0 128 KB (23LC1024)
	input      [1:0]  ms_port,        // OSD Mouse: 0 Off, 1 port 1, 2 port 2 (SNES mouse, uze_pads)
	input      [7:0]  ms_x,           // the USB mouse of the MCU
	input      [7:0]  ms_y,
	input      [7:0]  ms_b,
	input             ms_wr,
	input             uart_rxd,       // USART0: the ESP8266 (Uzenet)
	output            uart_txd,
	output            uart_cts,

	output     [20:0] sram_a,
	input      [15:0] sram_dq_i,
	output     [15:0] sram_dq_o,
	output            sram_dq_oe,
	output     [1:0]  sram_we_n,
	output     [1:0]  sram_oe_n,

	// the SD card: the card of the board (sd_image 0) or an image through the file mounter of the MCU
	input             sd_image,
	output            sd_cs_n,
	output            sd_sck,
	output            sd_mosi,
	input             sd_miso,
	// the file mounter of kg_mcu2 (SDC_*): slot 1 the SD image (kg_sd_emu), slot 2 the EEPROM file (kg_bk_ram)
	input      [7:0]  sdc_img_mounted,
	input      [63:0] sdc_img_size,
	output     [7:0]  sdc_rd,
	output     [7:0]  sdc_wr,
	output     [31:0] sdc_sector,
	input             sdc_busy,
	input             sdc_done,
	input             sdc_error,
	input      [2:0]  sdc_slot,
	input             sdc_byte_in_strobe,
	input      [8:0]  sdc_byte_addr,
	input      [7:0]  sdc_byte_in_data,
	output     [7:0]  sdc_byte_out_data,
	input      [7:0]  img_flush,
	output            bk_mount,
	output            bk_flushed,
	output     [31:0] bk_size,
	output     [7:0]  bk_kind,
	output     [7:0]  bk_result,

	output     [12:0] sdr_a,
	output     [1:0]  sdr_ba,
	input      [15:0] sdr_dq_i,
	output     [15:0] sdr_dq_o,
	output     [15:0] sdr_dq_oe_n,
	output     [1:0]  sdr_dqm,
	output            sdr_ras_n,
	output            sdr_cas_n,
	output            sdr_we_n,

	output     [23:0] rgb,              // clk_vid
	output            hs,
	output            vs,
	output            de,

	output reg [15:0] audio,
	output            running,
	output     [15:0] dbg_pc
);

// SD image (kg_sd_emu) <-> the file mounter
wire hd_rd, hd_wr;
wire [31:0] hd_lba /* verilator public_flat */;
wire [31:0] hd_rq_lba;
wire [7:0] hd_byte_out;

// SD image wait: while the card waits for a sector of the file mounter (or the end of a write), the whole ATmega
// and the video input stop (the MCU serves a sector in ~5 ms, slower than a card: streaming programs read
// garbage / time out, SD error 03). The game sees no time pass; the picture holds, the sound pauses. If the
// mounter does not answer in ~1.2 s the chip runs on (the program times out as without the wait).
wire        sd_waiting;
reg         sd_freeze /* verilator public_flat */ = 1'b0;
reg  [24:0] sd_wait_cnt = 25'd0;
reg         sd_wait_to = 1'b0;
always @(posedge clk) begin
	if (!sd_waiting) begin sd_wait_cnt <= 25'd0; sd_wait_to <= 1'b0; end
	else if (!sd_wait_to) begin sd_wait_cnt <= sd_wait_cnt + 25'd1; if (&sd_wait_cnt) sd_wait_to <= 1'b1; end
	sd_freeze <= sd_waiting && !sd_wait_to && !(&sd_wait_cnt);
end

// SPI RAM <-> SDRAM (uze_spiram <-> uze_fb)
wire        sr_req_tg, sr_we, sr_ack_tg;
wire [20:0] sr_word;
wire [1:0]  sr_lane;
wire [7:0]  sr_byte;
wire [31:0] sr_rdata;

// ---------------------------------------------------------------- reset and load
reg game_loaded = 1'b0, rom_loaded = 1'b0, cpu_rst = 1'b1;
wire bk_busy;
wire wdt_reset;
reg  [3:0] wdt_hold = 4'd0;               // a watchdog reset holds the CPU in reset 15 clocks
wire wdt_rst = wdt_hold != 4'd0;
always @(posedge clk)
	if (wdt_reset) wdt_hold <= 4'd15;
	else if (wdt_hold != 4'd0) wdt_hold <= wdt_hold - 4'd1;
always @(posedge clk) begin
	if (areset) begin game_loaded <= 1'b0; rom_loaded <= 1'b0; end
	else if (ld_start) begin if (ld_raw) rom_loaded <= 1'b0; else game_loaded <= 1'b0; end
	else if (ld_end) begin if (ld_raw) rom_loaded <= 1'b1; else game_loaded <= 1'b1; end
	cpu_rst <= areset | reset | ld_active | bk_busy | wdt_rst | (boot ? ~rom_loaded : ~game_loaded);
end
assign running = ~cpu_rst;
wire loading = ld_active;

// ---------------------------------------------------------------- the ATmega644
wire [14:0] pm_addr, pm_addr_nx;
wire [15:0] pm_rdata;
wire [7:0]  porta /* verilator public_flat */;
wire [7:0]  ddra, ddrb, portd, ddrd, ocr2a;   // (PORTA / PORTD are used by the SPI devices below)
wire [7:0]  pixel /* verilator public_flat */, portb /* verilator public_flat */;
wire [1:0]  pad_data /* verilator public_flat */;
wire        sample;
wire        spi_sck, spi_mosi, spi_start;
wire        spi_done /* verilator public_flat */;
wire [7:0]  spi_tx;
wire        spi_ext;
wire [7:0]  spi_rx_ext;
wire        spm_fill, spm_erase, spm_write, spm_busy;
wire [15:0] spm_z, spm_r;
wire        ee_req, ee_we, ee_ack, ee_cpu_wr;
wire [10:0] ee_cpu_addr;
wire [14:0] ee_addr;
wire [7:0]  ee_din, ee_dout;

atmega644 mcu (
	.clk(clk), .rst(cpu_rst), .reset_vec(boot ? 15'h7800 : 15'h0000),
	.pm_addr(pm_addr), .pm_addr_nx(pm_addr_nx), .pm_rdata(pm_rdata),
	.pina({porta[7:2], pad_data}), .pinb(portb), .pinc(8'd0), .pind(portd),
	.porta(porta), .ddra(ddra), .portb(portb), .ddrb(ddrb), .pixel(pixel), .portd(portd), .ddrd(ddrd),
	.ocr2a(ocr2a), .sample(sample),
	.spi_on(1'b1), .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_miso(sd_miso), .spi_start(spi_start),
	.spi_tx(spi_tx), .spi_done(spi_done), .spi_ext(spi_ext), .spi_rx_ext(spi_rx_ext),
	.spm_fill(spm_fill), .spm_erase(spm_erase), .spm_write(spm_write), .spm_z(spm_z), .spm_r(spm_r),
	.spm_busy(spm_busy), .freeze(sd_freeze),
	.ee_req(ee_req), .ee_we(ee_we), .ee_addr(ee_addr[10:0]), .ee_din(ee_din), .ee_ack(ee_ack), .ee_dout(ee_dout),
	.ee_cpu_wr(ee_cpu_wr), .ee_cpu_addr(ee_cpu_addr), .wdt_reset(wdt_reset),
	.uart_rxd(uart_rxd), .uart_txd(uart_txd), .uart_cts(uart_cts),
	.insn_start(), .dbg_pc(dbg_pc)
);

uze_pm_sram pm (
	.clk(clk), .loading(loading),
	// in reset the fetch address is the reset vector: the first word the CPU takes after its reset (26112011
	// took the last address of the loader there: Bootloader5 ran the word after its reset vector)
	.pm_addr_nx(cpu_rst ? (boot ? 15'h7800 : 15'h0000) : pm_addr_nx), .pm_rdata(pm_rdata),
	.ld_wr(ld_wr), .ld_raw(ld_raw), .ld_addr(ld_addr), .ld_data(ld_data), .ld_busy(),
	.spm_fill(spm_fill), .spm_erase(spm_erase), .spm_write(spm_write), .spm_z(spm_z), .spm_r(spm_r),
	.spm_busy(spm_busy),
	.sram_a(sram_a), .sram_dq_i(sram_dq_i), .sram_dq_o(sram_dq_o), .sram_dq_oe(sram_dq_oe),
	.sram_we_n(sram_we_n), .sram_oe_n(sram_oe_n)
);

uze_pads pads (.clk(clk), .porta(porta), .joy_l(joy_l), .joy_r(joy_r), .kbd(kbd), .rst(cpu_rst), .kb_mode(kb_mode),
	.ps2_code(ps2_code), .ps2_wr(ps2_wr), .kb_on(),
	.ms_port(ms_port), .ms_x(ms_x), .ms_y(ms_y), .ms_b(ms_b), .ms_wr(ms_wr), .data(pad_data));

wire        line_tg;
wire [1:0]  line_bank;
wire [7:0]  line_row;
wire [11:0] ring_addr;
wire [7:0]  ring_data;
uze_video #(.V_FIRST(V_FIRST)) video (
	.clk(clk), .rst(areset), .freeze(sd_freeze), .pixel(cpu_rst ? 8'd0 : pixel), .sync(portb[0]),
	.line_tg(line_tg), .line_bank(line_bank), .line_row(line_row), .frame_start(),
	.rd_clk(clk_sdr), .rd_addr(ring_addr), .rd_data(ring_data)
);

wire        wb_cyc, wb_stb, wb_we, wb_ack, sdr_ready;
wire [3:0]  wb_sel;
wire [24:2] wb_adr;
wire [2:0]  wb_cti;
wire [31:0] wb_dat_w, wb_dat_r;
uze_fb fb (
	.clk_sdr(clk_sdr), .rst_sdr(areset_sdr), .sdr_ready(sdr_ready),
	.line_tg(line_tg), .line_bank(line_bank), .line_row(line_row), .rd_addr(ring_addr), .rd_data(ring_data),
	.sr_req_tg(sr_req_tg), .sr_we(sr_we), .sr_word(sr_word), .sr_lane(sr_lane), .sr_byte(sr_byte),
	.sr_ack_tg(sr_ack_tg), .sr_rdata(sr_rdata),
	.wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_sel(wb_sel), .wb_adr(wb_adr), .wb_cti(wb_cti),
	.wb_dat_o(wb_dat_w), .wb_dat_i(wb_dat_r), .wb_ack(wb_ack),
	.clk_vid(clk_vid), .rgb(rgb), .hs(hs), .vs(vs), .de(de)
);

`ifdef UZE_SIM_SDRAM
// simulation: a wishbone RAM in place of the SDRAM controller (src/sim/system)
uze_wb_ram_sim sdram (
	.clk(clk_sdr), .reset(areset_sdr), .ready(sdr_ready),
	.wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_sel(wb_sel), .wb_adr(wb_adr), .wb_cti(wb_cti),
	.wb_dat_i(wb_dat_w), .wb_dat_o(wb_dat_r), .wb_ack(wb_ack)
);
assign sdr_a = 13'd0; assign sdr_ba = 2'd0; assign sdr_dq_o = 16'd0; assign sdr_dq_oe_n = 16'hFFFF;
assign sdr_dqm = 2'b11; assign sdr_ras_n = 1'b1; assign sdr_cas_n = 1'b1; assign sdr_we_n = 1'b1;
`else
uze_sdram sdram (
	.clk(clk_sdr), .reset(areset_sdr), .ready(sdr_ready),
	.wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_sel(wb_sel), .wb_adr(wb_adr), .wb_cti(wb_cti),
	.wb_dat_i(wb_dat_w), .wb_dat_o(wb_dat_r), .wb_ack(wb_ack),
	.sdr_a(sdr_a), .sdr_ba(sdr_ba), .sdr_dq_i(sdr_dq_i), .sdr_dq_o(sdr_dq_o), .sdr_dq_oe_n(sdr_dq_oe_n),
	.sdr_dqm(sdr_dqm), .sdr_ras_n(sdr_ras_n), .sdr_cas_n(sdr_cas_n), .sdr_we_n(sdr_we_n)
);
`endif

// ---------------------------------------------------------------- SPI devices
// SPI RAM: CS = PA4, SD card: CS = PD6 (kernel spiram.s / sdBase.S); an emulated device answers in bytes
wire cs_ram_n = porta[4] | ~ddra[4];
wire cs_sd_n = portd[6] | ~ddrd[6];
reg  [7:0] spi_txl = 8'd0;               // the byte of the transfer (spi_tx is valid at its start only)
always @(posedge clk) if (spi_start) spi_txl <= spi_tx;
wire [7:0] ram_rx;
wire [7:0] sd_out /* verilator public_flat */;
assign spi_ext = !cs_ram_n || (!cs_sd_n && sd_image);
assign spi_rx_ext = !cs_ram_n ? ram_rx : sd_out;
assign sd_cs_n = sd_image | cs_sd_n;
assign sd_sck = spi_sck;
assign sd_mosi = spi_mosi;

uze_spiram spiram (
	.clk(clk), .rst(areset), .big(spiram_big), .cs_n(cs_ram_n), .spi_start(spi_start), .spi_tx(spi_tx), .spi_done(spi_done),
	.rx(ram_rx), .late(),
	.m_req_tg(sr_req_tg), .m_we(sr_we), .m_word(sr_word), .m_lane(sr_lane), .m_byte(sr_byte),
	.m_ack_tg(sr_ack_tg), .m_rdata(sr_rdata)
);

kg_sd_emu #(.CACHE(1)) sd_emu (
	.clk(clk), .reset(cpu_rst),
	.xfer_in(spi_done), .tx_in(spi_txl), .cs_n(cs_sd_n | ~sd_image), .out_byte(sd_out),
	.img_mounted(sdc_img_mounted[1]), .img_size(|sdc_img_size[63:32] ? 32'hFFFFFE00 : sdc_img_size[31:0]),
	.hd_rd(hd_rd), .hd_wr(hd_wr), .hd_lba(hd_lba), .rq_lba(hd_rq_lba), .hd_busy(sdc_busy && sdc_slot == 3'd1),
	.hd_done(sdc_done && sdc_slot == 3'd1), .hd_error(sdc_error),
	.hd_byte_in_strobe(sdc_byte_in_strobe && sdc_slot == 3'd1), .hd_byte_addr(sdc_byte_addr),
	.hd_byte_in_data(sdc_byte_in_data), .hd_byte_out_data(hd_byte_out), .waiting(sd_waiting)
);

// ---------------------------------------------------------------- the EEPROM file (kg_bk_ram, slot 2)
// 2 KB = 4 sectors, <game>.sav next to the .uze: mounted after a game load (kind 0), read into the EEPROM before
// the CPU starts, the sectors the CPU writes saved ~1 s after its last write and before another game / core.
reg  game_end = 1'b0;
always @(posedge clk) game_end <= ld_end && !ld_raw;
wire [7:0]  bk_rd, bk_wr, bk_out;
wire [31:0] bk_sector;
kg_bk_ram #(.SLOT(3'd2), .LINK(2)) bk (
	.clk(clk), .reset(areset | (ld_start && !ld_raw)),
	.start(game_end), .size(7'd4), .kind(8'd0), .busy(bk_busy), .mounted(), .saving(), .save_error(),
	.wr(ee_cpu_wr), .wr_addr({4'd0, ee_cpu_addr}),
	.mem_req(ee_req), .mem_we(ee_we), .mem_addr(ee_addr), .mem_din(ee_din), .mem_ack(ee_ack), .mem_dout(ee_dout),
	.img_mounted(8'd0), .img_size(64'd0), .img_data_wr(1'b0), .img_data_addr(9'd0), .img_data(8'd0),
	.img_result_wr(1'b0), .img_result(8'd0), .img_sum(16'd0), .img_flush(img_flush), .img_q_wr(), .img_q_di(),
	.img_q_ack(1'b0),
	.sdc_img_mounted_i(sdc_img_mounted), .sdc_img_size_i(sdc_img_size), .sdc_rd_o(bk_rd), .sdc_wr_o(bk_wr),
	.sdc_sector_o(bk_sector), .sdc_busy_i(sdc_busy), .sdc_done_i(sdc_done), .sdc_error_i(sdc_error),
	.sdc_slot_i(sdc_slot), .sdc_byte_in_strobe_i(sdc_byte_in_strobe), .sdc_byte_addr_i(sdc_byte_addr),
	.sdc_byte_in_data_i(sdc_byte_in_data), .sdc_byte_out_data_o(bk_out),
	.bk_mount(bk_mount), .bk_flushed(bk_flushed), .bk_size(bk_size), .bk_kind(bk_kind), .bk_result(bk_result)
);

// the requests of both slots to the mounter; it serves the lowest slot first: the sector of the slot being
// served, or of the lowest one asking
assign sdc_rd = {bk_rd[7:3], bk_rd[2], hd_rd, 1'b0};
assign sdc_wr = {bk_wr[7:3], bk_wr[2], hd_wr, 1'b0};
assign sdc_sector = (sdc_busy ? sdc_slot == 3'd1 : (hd_rd | hd_wr)) ? hd_rq_lba : bk_sector;
assign sdc_byte_out_data = sdc_slot == 3'd1 ? hd_byte_out : bk_out;

// ---------------------------------------------------------------- sound
reg sample_d = 1'b0;                 // OCR2A holds the new sample one clock after the write
always @(posedge clk) begin
	sample_d <= sample;
	if (cpu_rst) audio <= 16'd0;
	else if (sample_d) audio <= {{4{~ocr2a[7]}}, ocr2a[6:0], 5'd0};   // -18 dB (26112005 at -12 dB still too loud)
end

endmodule
