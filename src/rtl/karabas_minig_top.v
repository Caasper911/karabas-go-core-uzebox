`timescale 1ns / 1ps
`default_nettype wire

/*
 Uzebox core for Karabas Mini rev.G (HDMI): uzebox.v (ATmega644 with its program memory in the board
 SRAM, the .uze loader, SNES pads, 720 x 480 video, sound) and the board: PLL, MCU link v2, OSD, HDMI,
 PCM5102, the LED matrix level meters.

 Clocks: PLL 1 (VCO 575 MHz = 50 / 2 * 23): clk_cpu 28.75 MHz (the Uzebox has 28.636: 0.4 % fast, a game
 frame of 60.29 Hz; also the MCU link), clk_sdr 71.875 MHz (the frame buffer SDRAM; SDR_CLK from the
 225 degree output through an ODDR2), 25 MHz for PLL 2 (VCO 675 MHz = 25 * 27): clk_vid 27 MHz (CEA
 720 x 480p 59.94 Hz: the OSD, HDMI), clk_hdmi / clk_hdmi_n 135 MHz; FT_CLK_OUT = clk_cpu / 4 (7.2 MHz).
 Video: uzebox.v writes the game picture into a frame buffer in the SDRAM (triple buffered) and reads
 it out in standard timing (user 2026-11-20: an output locked to the game lost the monitors).
 OSD items (index = position in core.json): 0 Game (FL slot 0, .uze), 1 Reset (F12).
*/

module karabas_minig_top (
	input wire CLK_50MHZ,

	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N,

	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

	output wire SD_CS_N,
	output wire SD_CLK,
	output wire SD_DI,
	input wire SD_DO,
	input wire SD_DET_N,

	input wire [7:0] VGA_R,
	input wire [7:0] VGA_G,
	input wire [7:0] VGA_B,
	input wire VGA_HS,
	input wire VGA_VS,

	output wire [3:0] TMDS_P,
	output wire [3:0] TMDS_N,

	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	input wire FT_DE,
	output wire FT_CLK_OUT,

	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,

	output wire TAPE_OUT,
	input wire TAPE_IN,

	output wire DAC_BCK,
	output wire DAC_WS,
	output wire DAC_DAT,

	output wire ADC_CLK,
	inout wire ADC_BCK,
	inout wire ADC_LRCK,
	input wire ADC_DOUT,

	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO,
	inout wire [5:0] MCU_IO, // [0] burst cs_n, [1] burst ready, [2] sd2 cs_n, [3] ft cs_n

	output wire MIDI_TX,

	output wire ESP32_SPI_CS_N,
	input wire ESP32_PCM_BCK,
	input wire ESP32_PCM_RLCK,
	input wire ESP32_PCM_DAT,

	output wire FLASH_CS_N,
	input wire FLASH_DO,
	output wire FLASH_DI,
	output wire FLASH_SCK,
	output wire FLASH_WP_N,
	output wire FLASH_HOLD_N
);

// ------------------------------------------------------------------ unused

assign WA = 3'b000;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b1;
assign WD = 16'bz;

assign ESP32_SPI_CS_N = 1'b1;
assign UART_RX = 1'bz;
assign UART_TX = 1'bz;
assign UART_CTS = 1'bz;

assign TAPE_OUT = 1'b0;
assign MIDI_TX = 1'b1;

// FLASH_CS_N (T3) is the SDRAM /CS of Mini G2 (rev G: tied low on the board): always selected
assign FLASH_CS_N = 1'b0;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;

assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'bz;
assign ADC_LRCK = 1'bz;

// the SD card of the FPGA: unused until Bootloader5 (Ф2); the MCU loads the games from its own card
assign SD_CS_N = 1'b1;
assign SD_CLK = 1'b0;
assign SD_DI = 1'b1;


// ------------------------------------------------------------------ clocks

wire [5:0] pll_clk;
wire pll_locked;
kg_pll #(
	.CLKIN_PERIOD(20.0),
	.DIVCLK_DIVIDE(2),       // PFD 25 MHz
	.CLKFBOUT_MULT(23),      // VCO 575 MHz
	.CLKOUT0_DIVIDE(20),     // clk_cpu 28.75 MHz
	.CLKOUT1_DIVIDE(8),      // clk_sdr 71.875 MHz
	.CLKOUT2_DIVIDE(8),      // clk_sdr_ph 71.875 MHz, 225 degrees (SDR_CLK)
	.CLKOUT2_PHASE(225.0),
	.CLKOUT3_DIVIDE(23),     // 25 MHz for PLL 2
	.CLKOUT4_DIVIDE(20),
	.CLKOUT5_DIVIDE(20),
	.BUFG_MASK(6'b001111)
) pll (
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked(pll_locked)
);
wire clk_cpu = pll_clk[0];
wire clk_sdr = pll_clk[1];
wire clk_sdr_ph = pll_clk[2];

wire [5:0] vpll_clk;
wire vpll_locked;
kg_pll #(
	.IBUFG(0),
	.CLKIN_PERIOD(40.0),
	.DIVCLK_DIVIDE(1),
	.CLKFBOUT_MULT(27),      // VCO 675 MHz
	.CLKOUT0_DIVIDE(25),     // clk_vid 27 MHz
	.CLKOUT1_DIVIDE(5),      // clk_hdmi 135 MHz
	.CLKOUT2_DIVIDE(5),      // clk_hdmi_n 135 MHz, 180 degrees
	.CLKOUT2_PHASE(180.0),
	.CLKOUT3_DIVIDE(25),
	.CLKOUT4_DIVIDE(25),
	.CLKOUT5_DIVIDE(25),
	.BUFG_MASK(6'b000111)
) vpll (
	.clk_in(pll_clk[3]),
	.rst(~pll_locked),
	.clk_out(vpll_clk),
	.locked(vpll_locked)
);
wire clk_vid = vpll_clk[0];
wire clk_hdmi = vpll_clk[1];
wire clk_hdmi_n = vpll_clk[2];

(* KEEP = "TRUE" *) wire areset_async = ~(pll_locked & vpll_locked);
wire areset, areset_sdr, areset_vid;
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_areset (.clk(clk_cpu), .d(areset_async), .q(areset));
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_areset_sdr (.clk(clk_sdr), .d(areset_async), .q(areset_sdr));
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_areset_vid (.clk(clk_vid), .d(areset_async), .q(areset_vid));

ODDR2 oddr_sdr_clk (.Q(SDR_CLK), .C0(clk_sdr_ph), .C1(~clk_sdr_ph), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

// FT_CLK_OUT: clk_cpu / 4 (the FT812 needs a clock on Mini G, always)
reg [1:0] ft_div = 2'd0;
always @(posedge clk_cpu) ft_div <= ft_div + 2'd1;
assign FT_CLK_OUT = ft_div[1];

// ------------------------------------------------------------------ MCU

wire mcu_sck_ibufg, mcu_sck;
IBUFG ibufg_mcu_sck (.I(MCU_SCK), .O(mcu_sck_ibufg));
BUFG bufg_mcu_sck (.I(mcu_sck_ibufg), .O(mcu_sck));

wire mcu_int;
assign MCU_IO[1] = mcu_int;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[5:2] = 4'bzzzz;

wire [55:0] kbd;
wire [15:0] joy_l, joy_r;
wire [23:0] matrix_cmd;
wire matrix_cmd_wr;
wire [1:0] ld_kind;
wire [7:0] ld_slot, ld_data;
wire [31:0] ld_addr;
wire ld_start, ld_active, ld_end, ld_wr;
wire [8*2-1:0] sw;
wire dvi_only;
wire ft_cs_n, ft_mosi, ft_spi_on;
wire [15:0] dbg_addr;
reg [15:0] dbg_data = 16'd0;
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;

kg_mcu2 #(
	.SW_N(2),
	.CS_FILTER(3),
	.CAPS(16'h0000),
	.ENABLE_OSD(1),
	.ENABLE_IMG(0),
	.ENABLE_AUX(1),      // the LED matrix level meters, DEBUG_* (AT+KARABAS=debug:1)
	.ENABLE_FT(1),
	.ENABLE_SD2(0)
) mcu (
	.CLK(clk_cpu),
	.N_RESET(~areset),

	.MCU_SCK(mcu_sck),
	.MCU_MOSI(MCU_MOSI),
	.MCU_MISO(MCU_MISO),
	.MCU_SS(MCU_CS_N),
	.MCU_INT(mcu_int),
	.MCU_SPI_FT_SS(MCU_IO[3]),
	.MCU_SPI_SD2_SS(MCU_IO[2]),

	.SW(sw), .SW_WR(), .SW_INDEX(), .SW_VALUE(), .HW_ID(), .DVI_ONLY(dvi_only), .CORE_BUILD(), .FW_BUILD(),
	.BUSY(), .BTNS(), .RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),

	.KBD(kbd), .KBD_WR(),
	.PS2_CODE(), .PS2_KIND(), .PS2_WR(),
	.MS_X(), .MS_Y(), .MS_Z(), .MS_B(), .MS_WR(),
	.JOY_L(joy_l), .JOY_R(joy_r), .JOY_WR(),
	.PS2_CMD(16'h0000), .PS2_CMD_WR(1'b0),

	.LD_KIND(ld_kind), .LD_SLOT(ld_slot), .LD_SIZE(), .LD_EXT(), .LD_START(ld_start), .LD_ACTIVE(ld_active), .LD_END(ld_end),
	.LD_ADDR(ld_addr), .LD_DATA(ld_data), .LD_WR(ld_wr), .LD_READY(1'b1),

	.OSD_WR(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
	.OSD_FG(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha), .OSD_PX(osd_px), .OSD_PY(osd_py),
	.OSD_PW(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),

	.SDC_IMG_MOUNTED(), .SDC_IMG_SIZE(), .SDC_RD(8'd0), .SDC_WR(8'd0),
	.SDC_SECTOR(32'd0), .SDC_BUSY(), .SDC_DONE(), .SDC_ERROR(), .SDC_SLOT(),
	.SDC_BYTE_IN_STROBE(), .SDC_BYTE_ADDR(), .SDC_BYTE_IN_DATA(),
	.SDC_BYTE_OUT_DATA(8'd0), .IMG_WP(), .IMG_PHYS_WR(), .IMG_PHYS(), .IMG_FLUSH(), .FDD_CHNG_WR(), .FDD_CHNG(),
	.BK_MOUNT(1'b0), .BK_FLUSHED(1'b0), .BK_SLOT(3'd0), .BK_SIZE(32'd0), .BK_KIND(8'd0), .BK_RESULT(8'd0),
	.FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0), .IMG_ACTIVE(),
	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'b1111), .PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0),
	.PORT_CFG(128'd0), .PORT_IN_FULL(), .PORT_STAT(), .PORT_STAT_WR(),
	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_CS(1'b0), .RTC_WR_N(1'b1), .MATRIX_CMD(matrix_cmd), .MATRIX_CMD_WR(matrix_cmd_wr),
	.DEBUG_ADDR(dbg_addr), .DEBUG_DATA(dbg_data), .RTC_DO(),

	.FT_SPI_ON(ft_spi_on), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(ft_mosi), .FT_MISO(FT_SPI_MISO),
	.FT_CS_N(ft_cs_n),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

assign FT_SPI_CS_N = ft_spi_on ? ft_cs_n : 1'b1;
assign FT_SPI_SCK = ft_spi_on ? mcu_sck_ibufg : 1'b1;
assign FT_SPI_MOSI = ft_spi_on ? ft_mosi : 1'b1;

wire sw_reset = sw[8];                 // OSD Reset (item index 1)
wire ld_game = ld_kind == 2'd2 && ld_slot == 8'd0;

// ------------------------------------------------------------------ the console

wire [15:0] sdr_dq_o, sdr_dq_oe_n;
genvar gi;
generate
	for (gi = 0; gi < 16; gi = gi + 1) begin : g_sdr_dq
		assign SDR_DQ[gi] = sdr_dq_oe_n[gi] ? 1'bz : sdr_dq_o[gi];
	end
endgenerate
wire [15:0] md_o;
wire md_oe;
assign MD = md_oe ? md_o : 16'bz;
wire [23:0] vid_rgb;
wire vid_hs, vid_vs, vid_de, running;
wire [15:0] snd;
wire [15:0] dbg_pc;

uzebox console (
	.clk(clk_cpu), .clk_sdr(clk_sdr), .areset_sdr(areset_sdr), .clk_vid(clk_vid), .areset(areset), .reset(sw_reset),
	.ld_start(ld_start & ld_game), .ld_active(ld_active & ld_game), .ld_end(ld_end & ld_game),
	.ld_wr(ld_wr & ld_game), .ld_addr(ld_addr), .ld_data(ld_data),
	.joy_l(joy_l), .joy_r(joy_r), .kbd(kbd),
	.sram_a(MA), .sram_dq_i(MD), .sram_dq_o(md_o), .sram_dq_oe(md_oe), .sram_we_n(MWR_N), .sram_oe_n(MRD_N),
	.sdr_a(SDR_A), .sdr_ba(SDR_BA), .sdr_dq_i(SDR_DQ), .sdr_dq_o(sdr_dq_o), .sdr_dq_oe_n(sdr_dq_oe_n),
	.sdr_dqm(SDR_DQM), .sdr_ras_n(SDR_RAS_N), .sdr_cas_n(SDR_CAS_N), .sdr_we_n(SDR_WE_N),
	.rgb(vid_rgb), .hs(vid_hs), .vs(vid_vs), .de(vid_de),
	.audio(snd), .running(running), .dbg_pc(dbg_pc)
);

// ------------------------------------------------------------------ video: OSD, HDMI

wire [23:0] osd_rgb;
wire osd_hs, osd_vs, osd_de;
kg_l2_osd_overlay osd (
	.wclk(clk_cpu),
	.osd_wr(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
	.osd_fg(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha), .osd_px(osd_px), .osd_py(osd_py),
	.osd_pw(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
	.icon_on(8'd0), .icon_act(8'd0),
	.clk(clk_vid),
	.rgb_i(vid_rgb), .hs_i(vid_hs), .vs_i(vid_vs), .de_i(vid_de),
	.rgb_o(osd_rgb), .hs_o(osd_hs), .vs_o(osd_vs), .de_o(osd_de)
);

// the sound: the 8-bit sample of the kernel (15.7 kHz) to the PCM5102 and the HDMI audio, mono.
// PCM5102: bck = 28.75 MHz / 16 = 1.8 MHz, 56 kHz frames (DIV_BITS 1 gave 112 kHz: no sound, 26112001)
kg_pcm5102 #(.DIV_BITS(2)) dac (.clk(clk_cpu), .reset(areset), .left(snd), .right(snd),
	.din(DAC_DAT), .bck(DAC_BCK), .lrck(DAC_WS));
audio_peaks #(.PERIOD_BITS(20)) peaks (.clk(clk_cpu), .audio_l(snd), .audio_r(snd),
	.cmd_wr(matrix_cmd_wr), .cmd(matrix_cmd));
// the sample to clk_vid: it changes once per game line (~1820 clocks): a toggle per change, taken
// when it arrives
reg [15:0] snd_d = 16'd0;
reg snd_tg = 1'b0;
always @(posedge clk_cpu) begin snd_d <= snd; if (snd != snd_d) snd_tg <= ~snd_tg; end
reg [2:0] snd_tg_v = 3'd0;
reg [15:0] snd_v = 16'd0;
always @(posedge clk_vid) begin
	snd_tg_v <= {snd_tg_v[1:0], snd_tg};
	if (snd_tg_v[2] ^ snd_tg_v[1]) snd_v <= snd_d;
end
// 48 kHz strobe for the HDMI audio: + 48 per clock of 27 MHz modulo 27000
reg [15:0] hacc = 16'd0;
reg aud_stb = 1'b0;
always @(posedge clk_vid) begin
	aud_stb <= 1'b0;
	if (hacc >= 16'd26952) begin hacc <= hacc + 16'd48 - 16'd27000; aud_stb <= 1'b1; end
	else hacc <= hacc + 16'd48;
end

reg dvi_only_p = 1'b0;
always @(posedge clk_vid) dvi_only_p <= dvi_only;
// HDMI starts 0.62 s (2^24 clocks of 27 MHz) after the PLLs lock: no TMDS at all before (the
// serializers in reset send no clock). A monitor that saw the first moments of the core (a game
// loaded at once) kept a wrong mode until the cable was plugged again (user 2026-11-20).
reg [24:0] hdmi_wait = 25'd0;
always @(posedge clk_vid)
	if (areset_vid) hdmi_wait <= 25'd0;
	else if (!hdmi_wait[24]) hdmi_wait <= hdmi_wait + 25'd1;
wire hdmi_reset = ~hdmi_wait[24];
reg hdmi_hs = 1'b1, hdmi_vs = 1'b1, hdmi_de = 1'b0;
reg [23:0] hdmi_rgb = 24'd0;
always @(posedge clk_vid) begin
	hdmi_hs <= ~osd_hs;
	hdmi_vs <= ~osd_vs;
	hdmi_de <= osd_de;
	hdmi_rgb <= osd_rgb;
end
hdmi_tx #(.SAMPLE_FREQ(48000)) hdmi (
	.clk(clk_vid), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(hdmi_reset),
	.rgb(hdmi_rgb), .vsync(hdmi_vs), .hsync(hdmi_hs), .de(hdmi_de),
	.audio_en(~dvi_only_p), .audio_l({ snd_v, 8'h00 }), .audio_r({ snd_v, 8'h00 }), .audio_clk(aud_stb),
	.tx_clk_n(TMDS_N[3]), .tx_clk_p(TMDS_P[3]), .tx_d_n(TMDS_N[2:0]), .tx_d_p(TMDS_P[2:0])
);

// ------------------------------------------------------------------ debug (AT+KARABAS=debug:1)

assign dbg_addr = { running, 15'd0 };
always @(posedge clk_cpu) dbg_data <= dbg_pc;

endmodule
