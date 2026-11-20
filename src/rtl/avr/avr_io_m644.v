// avr_io_m644.v - the IO registers of the ATmega644 that the Uzebox kernel uses, Verilog-2001 for XST.
//
// karabas-go-core-uzebox, GPL-3.0-or-later. Behaviour follows Uzem (tools/uzem/avr8.cpp) where the
// games depend on it, the datasheet elsewhere:
//   - timer 1 counts every cycle when started (the kernel uses no prescaler), normal and CTC (OCR1A)
//     modes; its compare / overflow flags appear in TIFR1 one cycle after the event; an OCR1x write
//     is seen by the compare of the same cycle; TCNT1 / TEMP as in the datasheet;
//   - watchdog: Uzem's model (only used to seed the random generator): 457142 cycles at WDP = 0,
//     counted per instruction, WDIF set at the end of an instruction;
//   - EEPROM 2 KB: a read halts the CPU 4 cycles, a write 2 cycles (contents start at 0, as Uzem);
//   - PORTC: the pixel (value AND DDRC at the write), PORTD stores value AND DDRD (as Uzem);
//   - OCR2A write: the audio sample (the kernel writes it once per line), PWM is not generated;
//   - SPI master, SPM, MCUCR IVSEL (Bootloader5), USART0 (below: the ESP8266 of Uzenet);
//   - all other registers (timer 0 / 2, ...) read back what was written.
// IO index = data address - 0x20. Interrupt vectors (word addresses): WDT 0x10, TIMER1_COMPA 0x1A,
// TIMER1_COMPB 0x1C, TIMER1_OVF 0x1E, USART0_RX 0x28, USART0_UDRE 0x2A, USART0_TX 0x2C.

module avr_io_m644 (
	input             clk,
	input             rst,

	input      [7:0]  io_addr,
	input             io_rd,
	input             io_wr,
	input      [7:0]  io_wdata,
	input      [7:0]  io_bitmask,
	output reg [7:0]  io_rdata,

	output            irq,
	output reg [5:0]  irq_vec,
	output reg        ivsel,        // MCUCR IVSEL: the vectors are in the boot section (0x7800 + vector)
	input             irq_ack,
	input             wdr,
	input             insn_end,
	output            halt,

	input      [7:0]  pina,
	input      [7:0]  pinb,
	input      [7:0]  pinc,
	input      [7:0]  pind,
	output reg [7:0]  porta,
	output reg [7:0]  ddra,
	output reg [7:0]  portb,
	output reg [7:0]  ddrb,
	output reg [7:0]  pixel,
	output reg [7:0]  portd,
	output reg [7:0]  ddrd,

	output reg [7:0]  ocr2a,
	output            sample,       // OCR2A written while timer 2 runs

	// SPI master (mode 0, MSB first): the pins (a real SD card) and a byte port for emulated devices
	input             spi_on,       // 0: no transfers, SPDR / SPSR / SPCR read back (Uzem without an SD card)
	output reg        spi_sck,
	output reg        spi_mosi,
	input             spi_miso,
	output            spi_start,    // one clock: a transfer of spi_tx starts (an SPDR write)
	output     [7:0]  spi_tx,
	output            spi_done,     // one clock: the transfer ends, SPDR takes the received byte
	input             spi_ext,      // at spi_done: take spi_rx_ext (an emulated device) instead of MISO
	input      [7:0]  spi_rx_ext,

	// SPM (self programming): the operation for the program memory, SPMEN cleared when it is done
	input             spm,          // the CPU executes SPM: spm_z = Z, spm_r = r1:r0
	input      [15:0] spm_z,
	input      [15:0] spm_r,
	output            spm_fill,     // one clock: page buffer word spm_z[7:1] = spm_r
	output            spm_erase,    // one clock: erase page spm_z[15:8]
	output            spm_write,    // one clock: write the page buffer to page spm_z[15:8]
	input             spm_busy,     // the program memory erases / writes (the CPU is halted meanwhile)
	input             ext_halt,     // halt the CPU (SPM)
	input             freeze,       // stop the whole chip (CPU, timer 1, watchdog, EEPROM, SPI): the uzebox waits for
	                                // a sector of the SD image, the game sees no time pass

	// EEPROM: a second port (kg_bk_ram: the .sav file) and the writes of the CPU
	input             ee_req,       // held until ee_ack
	input             ee_we,
	input      [10:0] ee_addr,
	input      [7:0]  ee_din,
	output reg        ee_ack,
	output reg [7:0]  ee_dout,
	output            ee_cpu_wr,    // the CPU wrote eeprom[ee_cpu_addr]
	output     [10:0] ee_cpu_addr,

	output            wdt_reset,    // the watchdog times out in system reset mode: reset the MCU

	// USART0 (PD0 RXD0 / PD1 TXD0): the ESP8266 of Uzenet
	input             uart_rxd,
	output reg        uart_txd,
	output            uart_cts      // 1 = the receive fifo is filling: the other side should stop
);

localparam A_PINA = 8'h00, A_DDRA = 8'h01, A_PORTA = 8'h02, A_PINB = 8'h03, A_DDRB = 8'h04, A_PORTB = 8'h05,
           A_PINC = 8'h06, A_DDRC = 8'h07, A_PORTC = 8'h08, A_PIND = 8'h09, A_DDRD = 8'h0A, A_PORTD = 8'h0B,
           A_TIFR1 = 8'h16, A_EECR = 8'h1F, A_EEDR = 8'h20, A_EEARL = 8'h21, A_EEARH = 8'h22,
           A_WDTCSR = 8'h40, A_TIMSK1 = 8'h4F, A_TCCR1B = 8'h61, A_TCNT1L = 8'h64, A_TCNT1H = 8'h65,
           A_OCR1AL = 8'h68, A_OCR1AH = 8'h69, A_OCR1BL = 8'h6A, A_OCR1BH = 8'h6B,
           A_TCCR2B = 8'h91, A_OCR2A = 8'h93, A_SPCR = 8'h2C, A_SPSR = 8'h2D, A_SPDR = 8'h2E, A_SPMCSR = 8'h37, A_MCUCR = 8'h35,
           A_UCSR0A = 8'hA0, A_UCSR0B = 8'hA1, A_UCSR0C = 8'hA2, A_UBRR0L = 8'hA4, A_UBRR0H = 8'hA5, A_UDR0 = 8'hA6;
localparam WDT_CYCLES = 20'd457142;

wire wr = io_wr;
wire bitop = io_bitmask != 8'd0;

// ---------------------------------------------------------------- generic registers
reg [7:0] gen [0:255] /* verilator public_flat */;
always @(posedge clk)
	if (wr) gen[io_addr] <= io_wdata;
wire [7:0] gen_q = gen[io_addr];

// ---------------------------------------------------------------- ports
reg [7:0] ddrc /* verilator public_flat */;
reg [7:0] portc /* verilator public_flat */;
always @(posedge clk) begin
	if (rst) begin
		porta <= 8'd0; ddra <= 8'd0; portb <= 8'd0; ddrb <= 8'd0; portc <= 8'd0; ddrc <= 8'd0;
		portd <= 8'd0; ddrd <= 8'd0; pixel <= 8'd0;
	end else if (wr) begin
		case (io_addr)
			A_PORTA: porta <= io_wdata;
			A_DDRA:  ddra  <= io_wdata;
			A_PORTB: portb <= io_wdata;
			A_DDRB:  ddrb  <= io_wdata;
			A_PORTC: begin portc <= io_wdata; pixel <= io_wdata & ddrc; end
			A_DDRC:  ddrc  <= io_wdata;
			A_PORTD: portd <= io_wdata & ddrd;
			A_DDRD:  ddrd  <= io_wdata;
			default: ;
		endcase
	end
end

// ---------------------------------------------------------------- timer 1
reg  [15:0] tcnt1 /* verilator public_flat */;
reg  [7:0]  temp;
reg  [7:0]  tccr1b /* verilator public_flat */;
reg  [15:0] ocr1a /* verilator public_flat */, ocr1b /* verilator public_flat */;
reg  [7:0]  timsk1 /* verilator public_flat */;
reg  [7:0]  tifr1 /* verilator public_flat */;
reg  [2:0]  t1_ev;          // events of the last cycle: {OCF1B, OCF1A, TOV1}, into TIFR1 now

wire [15:0] ocr1a_e = (wr && io_addr == A_OCR1AL) ? {ocr1a[15:8], io_wdata} :
                      (wr && io_addr == A_OCR1AH) ? {io_wdata, ocr1a[7:0]} : ocr1a;
wire [15:0] ocr1b_e = (wr && io_addr == A_OCR1BL) ? {ocr1b[15:8], io_wdata} :
                      (wr && io_addr == A_OCR1BH) ? {io_wdata, ocr1b[7:0]} : ocr1b;
wire        t1_on  = tccr1b[2:0] != 3'd0;
wire        t1_ctc = tccr1b[3];
wire        ev_tov = t1_on && tcnt1 == 16'hFFFF;
wire        ev_a   = t1_on && t1_ctc && tcnt1 == ocr1a_e;
wire        ev_b   = t1_on && t1_ctc && tcnt1 == ocr1b_e;

// interrupt selection (fixed priority = vector order)
reg  [7:0] wdtcsr /* verilator public_flat */;
wire irq_wdt = wdtcsr[7] & wdtcsr[6];
wire irq_t1a = tifr1[1] & timsk1[1];
wire irq_t1b = tifr1[2] & timsk1[2];
wire irq_t1o = tifr1[0] & timsk1[0];
wire irq_t1 = irq_t1a | irq_t1b | irq_t1o;
wire irq_rx, irq_udre, irq_tx;   // USART0
assign irq = irq_wdt | irq_t1 | irq_rx | irq_udre | irq_tx;
always @* begin
	if (irq_wdt)      irq_vec = 6'h10;
	else if (irq_t1a) irq_vec = 6'h1A;
	else if (irq_t1b) irq_vec = 6'h1C;
	else if (irq_t1o) irq_vec = 6'h1E;
	else if (irq_rx)  irq_vec = 6'h28;
	else if (irq_udre) irq_vec = 6'h2A;
	else              irq_vec = 6'h2C;
end
wire [7:0] t1_ack = (irq_ack && !irq_wdt && irq_t1) ? (irq_t1a ? 8'h02 : irq_t1b ? 8'h04 : 8'h01) : 8'h00;
wire [7:0] t1_clr = (wr && io_addr == A_TIFR1) ? (bitop ? (io_wdata & io_bitmask) : io_wdata) : 8'h00;

always @(posedge clk) begin
	if (rst) begin
		tcnt1 <= 16'd0; temp <= 8'd0; tccr1b <= 8'd0; ocr1a <= 16'd0; ocr1b <= 16'd0; timsk1 <= 8'd0;
		tifr1 <= 8'd0; t1_ev <= 3'd0;
	end else if (!freeze) begin
		tifr1 <= (tifr1 & ~t1_clr & ~t1_ack) | {5'd0, t1_ev};
		t1_ev <= {ev_b, ev_a, ev_tov};
		if (t1_on) tcnt1 <= ev_a ? 16'd0 : tcnt1 + 16'd1;
		if (io_rd && io_addr == A_TCNT1L) temp <= tcnt1[15:8];
		if (wr) begin
			case (io_addr)
				A_TCNT1H: temp <= io_wdata;
				A_TCNT1L: tcnt1 <= {temp, io_wdata};
				A_TCCR1B: tccr1b <= io_wdata;
				A_OCR1AL: ocr1a[7:0] <= io_wdata;
				A_OCR1AH: ocr1a[15:8] <= io_wdata;
				A_OCR1BL: ocr1b[7:0] <= io_wdata;
				A_OCR1BH: ocr1b[15:8] <= io_wdata;
				A_TIMSK1: timsk1 <= io_wdata;
				default: ;
			endcase
		end
	end
end

// ---------------------------------------------------------------- watchdog (Uzem model)
// WDE + WDIE: the interrupt (as Uzem); WDE alone: a system reset after the time-out (the kernel's SoftReset
// enables it to restart into the bootloader: START + SELECT + Y + B); Uzem has no reset.
reg wdt_reset_r = 1'b0;
assign wdt_reset = wdt_reset_r;
reg  [19:0] wdt_acc;     // cycles since the last instruction end
reg  [19:0] wdt_cnt /* verilator public_flat */;
wire [7:0]  wdtcsr_e = (wr && io_addr == A_WDTCSR) ? io_wdata : wdtcsr;
wire [19:0] wdt_base = wdr ? 20'd0 : wdt_cnt;
wire [20:0] wdt_sum  = {1'b0, wdt_base} + {1'b0, wdt_acc} + 21'd1;
always @(posedge clk) begin
	if (rst) begin
		wdtcsr <= 8'd0; wdt_acc <= 20'd0; wdt_cnt <= 20'd0; wdt_reset_r <= 1'b0;
	end else if (!freeze) begin
		if (wr && io_addr == A_WDTCSR) wdtcsr <= io_wdata;
		if (irq_ack && irq_wdt) wdtcsr[7] <= 1'b0;
		if (insn_end) begin
			wdt_acc <= 20'd0;
			if (wdtcsr_e[3]) begin
				if (wdt_sum >= {1'b0, WDT_CYCLES} && wdtcsr_e[6]) begin
					wdtcsr[7] <= 1'b1; wdt_cnt <= 20'd0;
				end else if (wdt_sum >= {1'b0, WDT_CYCLES}) begin
					wdt_reset_r <= 1'b1;                      // system reset mode (WDE, no WDIE): SoftReset
				end else
					wdt_cnt <= wdt_sum[20] ? 20'hFFFFF : wdt_sum[19:0];
			end else if (wdr) wdt_cnt <= 20'd0;
		end else begin
			wdt_acc <= wdt_acc + 20'd1;
			if (wdr) wdt_cnt <= 20'd0;
		end
	end
end

// ---------------------------------------------------------------- EEPROM
reg  [7:0]  eecr /* verilator public_flat */, eedr /* verilator public_flat */;
reg  [10:0] eear;
reg  [7:0]  eeprom [0:2047];
reg  [7:0]  ee_q;
reg  [2:0]  ee_halt;     // CPU halt cycles left
reg         ee_rd, ee_wr;
integer k;
initial for (k = 0; k < 2048; k = k + 1) eeprom[k] = 8'h00;
always @(posedge clk) begin
	if (ee_wr) eeprom[eear] <= eedr;
	ee_q <= eeprom[eear];
end
// port b: kg_bk_ram (a request at a time, acked the clock after)
initial begin ee_ack = 1'b0; ee_dout = 8'd0; end
always @(posedge clk) begin
	ee_ack <= ee_req && !ee_ack;
	if (ee_req && !ee_ack) begin
		if (ee_we) eeprom[ee_addr] <= ee_din;
		ee_dout <= eeprom[ee_addr];
	end
end
assign ee_cpu_wr = ee_wr;
assign ee_cpu_addr = eear;
assign halt = ee_halt != 3'd0 || ext_halt || freeze;
always @(posedge clk) begin
	if (rst) begin
		eecr <= 8'd0; eedr <= 8'd0; eear <= 11'd0; ee_halt <= 3'd0; ee_rd <= 1'b0; ee_wr <= 1'b0;
	end else if (!freeze) begin
		ee_wr <= 1'b0;
		if (ee_halt != 3'd0) begin
			ee_halt <= ee_halt - 3'd1;
			if (ee_halt == 3'd1 && ee_rd) begin eedr <= ee_q; ee_rd <= 1'b0; end
		end
		if (wr) begin
			case (io_addr)
				A_EEDR:  eedr <= io_wdata;
				A_EEARL: eear[7:0] <= io_wdata;
				A_EEARH: eear[10:8] <= io_wdata[2:0];
				A_EECR: begin
					eecr <= io_wdata;
					if (io_wdata[0]) begin                        // EERE: read
						eecr[0] <= 1'b0; ee_rd <= 1'b1; ee_halt <= 3'd4;
					end else if (io_wdata[1] && eecr[2]) begin    // EEPE after EEMPE: write
						eecr[2:1] <= 2'b00; ee_wr <= 1'b1; ee_halt <= 3'd2;
					end
				end
				default: ;
			endcase
		end
	end
end

// ---------------------------------------------------------------- timer 2 (audio sample)
reg [7:0] tccr2b;
always @(posedge clk) begin
	if (rst) begin
		ocr2a <= 8'd0; tccr2b <= 8'd0;
	end else if (wr) begin
		if (io_addr == A_OCR2A) ocr2a <= io_wdata;
		if (io_addr == A_TCCR2B) tccr2b <= io_wdata;
	end
end
assign sample = wr && io_addr == A_OCR2A && tccr2b != 8'd0;

// ---------------------------------------------------------------- SPI master
// A transfer takes 8 x div clocks, div = 4 / 16 / 64 / 128 by SPR1:0, halved by SPI2X (the kernel's SD and SPI RAM
// code at fosc / 2 reads SPDR a fixed 17 clocks after its write: the byte is there after 16). SPIF is cleared by
// reading SPSR with SPIF set and then accessing SPDR (datasheet); a write during a transfer sets WCOL and is lost.
reg  [7:0] spcr /* verilator public_flat */ = 8'd0;
reg  [7:0] spsr /* verilator public_flat */ = 8'd0;
reg  [7:0] spdr_rx = 8'd0;
reg  [7:0] spi_sh = 8'd0;        // out: the bits still to send; in: the bits received
reg  [7:0] spi_txr = 8'd0;
reg        spi_busy = 1'b0;
reg  [10:0] spi_cnt = 11'd0;     // clocks of the transfer
reg  [6:0] spi_hc = 7'd0;        // clocks of the half bit
reg        spif_arm = 1'b0;
reg        spi_done_r = 1'b0;
wire [7:0] spi_div = (spcr[1:0] == 2'd0 ? 8'd4 : spcr[1:0] == 2'd1 ? 8'd16 : spcr[1:0] == 2'd2 ? 8'd64 : 8'd128) >> spsr[0];
wire [6:0] spi_half = spi_div[7:1];
wire       spdr_wr = wr && io_addr == A_SPDR;
wire       spdr_acc = (wr || io_rd) && io_addr == A_SPDR;
wire       spi_go = spdr_wr && spi_on && spcr[6] && !spi_busy;
assign spi_start = spi_go;
assign spi_tx = io_wdata;
assign spi_done = spi_done_r;
initial begin spi_sck = 1'b0; spi_mosi = 1'b1; end
always @(posedge clk) begin
	spi_done_r <= 1'b0;
	if (rst) begin
		spcr <= 8'd0; spsr <= 8'd0; spi_busy <= 1'b0; spi_sck <= 1'b0; spi_mosi <= 1'b1; spif_arm <= 1'b0;
	end else if (!freeze) begin
		if (wr && io_addr == A_SPCR) spcr <= io_wdata;
		if (wr && io_addr == A_SPSR) spsr <= spi_on ? {spsr[7:1], io_wdata[0]} : io_wdata;
		if (io_rd && io_addr == A_SPSR && spsr[7]) spif_arm <= 1'b1;
		if (spdr_acc && spif_arm) begin spsr[7:6] <= 2'b00; spif_arm <= 1'b0; end
		if (!spi_on && spdr_wr) spdr_rx <= io_wdata;
		if (spdr_wr && spi_on && spi_busy) spsr[6] <= 1'b1;            // WCOL
		if (spi_go) begin
			spi_busy <= 1'b1; spi_cnt <= 11'd0; spi_hc <= 7'd0; spi_sh <= io_wdata; spi_txr <= io_wdata;
			spi_mosi <= io_wdata[7]; spi_sck <= 1'b0;
		end else if (spi_busy) begin
			spi_cnt <= spi_cnt + 11'd1;
			if (spi_hc == spi_half - 7'd1) begin
				spi_hc <= 7'd0;
				spi_sck <= ~spi_sck;
				if (!spi_sck) spi_sh <= {spi_sh[6:0], spi_miso};       // rising edge: a bit in
				else spi_mosi <= spi_sh[7];                             // falling edge: the next bit out
			end else spi_hc <= spi_hc + 7'd1;
			if (spi_cnt == {spi_div, 3'd0} - 11'd1) begin
				spi_busy <= 1'b0; spi_sck <= 1'b0; spi_done_r <= 1'b1;
				spsr[7] <= 1'b1;
				spdr_rx <= spi_ext ? spi_rx_ext : spi_sh;
			end
		end
	end
end

// ---------------------------------------------------------------- USART0
// Asynchronous 8N1 (UCSR0C is stored, not used), bit = 16 x (UBRR + 1) clocks, 8 x with U2X0. Receive: a 16-byte
// fifo (the ATmega has 2): RXC0 while it holds a byte, a UDR0 read takes it; a byte with the fifo full is lost
// (DOR0, until the next UDR0 read); FE0 a 0 stop bit. uart_cts rises at 8 bytes (the ESP stops after its byte).
// Transmit: UDR0 -> buffer (UDRE0 = empty) -> shifter; TXC0 when the shifter ends with the buffer empty
// (cleared by writing 1 or by its interrupt). The kernel polls the flags once a line (soundMixerInline.s).
// The USART runs while the chip is frozen (the ESP does not stop; the fifo and CTS take the bytes).
reg  [7:0]  ucsr0b = 8'd0;
reg  [7:0]  ucsr0c /* verilator public_flat */ = 8'h06;
reg  [11:0] ubrr0 /* verilator public_flat */ = 12'd0;
reg         u2x = 1'b0, mpcm = 1'b0, txc = 1'b0, fe = 1'b0, dor = 1'b0;
wire [11:0] ubrr1 = ubrr0 + 12'd1;
wire [16:0] u_per = u2x ? {2'd0, ubrr1, 3'd0} : {1'b0, ubrr1, 4'd0};
wire        rxen = ucsr0b[4], txen = ucsr0b[3];
// receive
reg  [7:0]  rq [0:15];
reg  [3:0]  rq_wp = 4'd0, rq_rp = 4'd0;
reg  [4:0]  rq_n = 5'd0;
reg  [2:0]  rx_s = 3'b111;          // synchroniser
reg  [16:0] rx_t = 17'd0;
reg  [3:0]  rx_b = 4'd0;            // 0 idle, 1 start, 2..9 data, 10 stop
reg  [7:0]  rx_sh = 8'd0;
wire        udr_rd = io_rd && io_addr == A_UDR0;
wire        rq_pop = udr_rd && rq_n != 5'd0;
reg         rq_push = 1'b0;
reg  [7:0]  rq_d = 8'd0;
wire        rq_in = rq_push && rq_n != 5'd16;
assign uart_cts = rq_n >= 5'd8;
always @(posedge clk) begin
	rx_s <= {rx_s[1:0], uart_rxd};
	rq_push <= 1'b0;
	if (rst || !rxen) begin
		rx_b <= 4'd0;
	end else if (rx_b == 4'd0) begin
		if (!rx_s[2]) begin rx_b <= 4'd1; rx_t <= {1'b0, u_per[16:1]}; end      // start: the middle of the bit
	end else if (rx_t != 17'd1) begin
		rx_t <= rx_t - 17'd1;
	end else begin
		rx_t <= u_per;
		rx_b <= rx_b + 4'd1;
		if (rx_b == 4'd1 && rx_s[2]) rx_b <= 4'd0;                                // a glitch, not a start bit
		if (rx_b >= 4'd2 && rx_b <= 4'd9) rx_sh <= {rx_s[2], rx_sh[7:1]};
		if (rx_b == 4'd10) begin
			rx_b <= 4'd0;
			fe <= !rx_s[2];
			rq_d <= rx_sh; rq_push <= 1'b1;
		end
	end
	if (rq_in) begin rq[rq_wp] <= rq_d; rq_wp <= rq_wp + 4'd1; end
	if (rq_pop) rq_rp <= rq_rp + 4'd1;
	rq_n <= rq_n + {4'd0, rq_in} - {4'd0, rq_pop};
	if (rq_push && rq_n == 5'd16) dor <= 1'b1;
	else if (udr_rd) dor <= 1'b0;
	if (rst) begin rq_wp <= 4'd0; rq_rp <= 4'd0; rq_n <= 5'd0; dor <= 1'b0; fe <= 1'b0; end
end
wire rxc = rq_n != 5'd0;
// transmit
reg         tx_full = 1'b0;
reg  [7:0]  tx_buf = 8'd0;
reg  [9:0]  tx_sh = 10'h3FF;
reg  [3:0]  tx_n = 4'd0;            // bits left in the shifter
reg  [16:0] tx_t = 17'd0;
wire        udr_wr = wr && io_addr == A_UDR0;
wire        txc_clr = wr && io_addr == A_UCSR0A && (bitop ? (io_bitmask & io_wdata & 8'h40) != 8'd0 : io_wdata[6]);
initial uart_txd = 1'b1;
always @(posedge clk) begin
	if (rst) begin
		ucsr0b <= 8'd0; ucsr0c <= 8'h06; ubrr0 <= 12'd0; u2x <= 1'b0; mpcm <= 1'b0; txc <= 1'b0;
		tx_full <= 1'b0; tx_n <= 4'd0; uart_txd <= 1'b1;
	end else begin
		if (wr) case (io_addr)
			A_UCSR0A: begin u2x <= io_wdata[1]; mpcm <= io_wdata[0]; end
			A_UCSR0B: ucsr0b <= io_wdata;
			A_UCSR0C: ucsr0c <= io_wdata;
			A_UBRR0L: ubrr0[7:0] <= io_wdata;
			A_UBRR0H: ubrr0[11:8] <= io_wdata[3:0];
			default: ;
		endcase
		if (txc_clr || (irq_ack && irq_vec == 6'h2C)) txc <= 1'b0;
		if (udr_wr && txen && !tx_full) begin tx_buf <= io_wdata; tx_full <= 1'b1; end
		if (tx_n == 4'd0) begin
			if (tx_full) begin
				tx_sh <= {1'b1, tx_buf, 1'b0}; tx_n <= 4'd10; tx_t <= u_per; tx_full <= 1'b0;
				uart_txd <= 1'b0;
			end
		end else if (tx_t != 17'd1) begin
			tx_t <= tx_t - 17'd1;
		end else begin
			tx_t <= u_per;
			tx_sh <= {1'b1, tx_sh[9:1]};
			uart_txd <= tx_sh[1];
			tx_n <= tx_n - 4'd1;
			if (tx_n == 4'd1) begin uart_txd <= 1'b1; if (!tx_full) txc <= 1'b1; end
		end
		if (!txen) begin tx_n <= 4'd0; tx_full <= 1'b0; uart_txd <= 1'b1; end
	end
end
wire udre = !tx_full;
wire [7:0] ucsr0a /* verilator public_flat */ = {rxc, txc, udre, fe, dor, 1'b0, u2x, mpcm};
assign irq_rx = ucsr0b[7] && rxc;
assign irq_udre = ucsr0b[5] && udre;
assign irq_tx = ucsr0b[6] && txc;

// ---------------------------------------------------------------- SPM
// SPMCSR (0x37): SPMEN 0, PGERS 1, PGWRT 2, BLBSET 3, RWWSRE 4, SIGRD 5, RWWSB 6, SPMIE 7. An SPM with SPMEN set
// does: PGERS -> erase, PGWRT -> write, RWWSRE / BLBSET / SIGRD -> nothing, none -> fill the page buffer; the
// bits clear when the operation is done (the program memory holds spm_busy, the CPU halted meanwhile).
reg  [7:0] spmcsr = 8'd0;
wire       spm_go = spm && spmcsr[0];
assign spm_fill  = spm_go && spmcsr[5:1] == 5'd0;
assign spm_erase = spm_go && spmcsr[1];
assign spm_write = spm_go && spmcsr[2] && !spmcsr[1];
reg        spm_wait = 1'b0;
always @(posedge clk) begin
	if (rst) begin spmcsr <= 8'd0; spm_wait <= 1'b0; end
	else begin
		if (wr && io_addr == A_SPMCSR) spmcsr <= io_wdata;
		if (spm_go) begin
			if (spm_erase || spm_write) spm_wait <= 1'b1;
			else spmcsr[5:0] <= 6'd0;               // fill, RWWSRE, ...: done at once
		end
		if (spm_wait && !spm_busy && !spm_go) begin spm_wait <= 1'b0; spmcsr[5:0] <= 6'd0; end
	end
end

// ---------------------------------------------------------------- MCUCR IVSEL (Bootloader5 moves the vectors)
// a write with IVCE allows a change of IVSEL by the next write within 4 cycles (datasheet)
reg [2:0] ivce_cnt = 3'd0;
initial ivsel = 1'b0;
always @(posedge clk) begin
	if (rst) begin ivsel <= 1'b0; ivce_cnt <= 3'd0; end
	else if (!freeze) begin
		if (ivce_cnt != 3'd0) ivce_cnt <= ivce_cnt - 3'd1;
		if (wr && io_addr == A_MCUCR) begin
			if (io_wdata[0]) ivce_cnt <= 3'd4;
			else if (ivce_cnt != 3'd0) begin ivsel <= io_wdata[1]; ivce_cnt <= 3'd0; end
		end
	end
end

// ---------------------------------------------------------------- read
always @* begin
	case (io_addr)
		A_PINA:   io_rdata = pina;
		A_PINB:   io_rdata = pinb;
		A_PINC:   io_rdata = pinc;
		A_PIND:   io_rdata = pind;
		A_PORTA:  io_rdata = porta;
		A_DDRA:   io_rdata = ddra;
		A_PORTB:  io_rdata = portb;
		A_DDRB:   io_rdata = ddrb;
		A_PORTC:  io_rdata = portc;
		A_DDRC:   io_rdata = ddrc;
		A_PORTD:  io_rdata = portd;
		A_DDRD:   io_rdata = ddrd;
		A_TIFR1:  io_rdata = tifr1;
		A_TIMSK1: io_rdata = timsk1;
		A_TCCR1B: io_rdata = tccr1b;
		A_TCNT1L: io_rdata = tcnt1[7:0];
		A_TCNT1H: io_rdata = temp;
		A_OCR1AL: io_rdata = ocr1a[7:0];
		A_OCR1AH: io_rdata = ocr1a[15:8];
		A_OCR1BL: io_rdata = ocr1b[7:0];
		A_OCR1BH: io_rdata = ocr1b[15:8];
		A_WDTCSR: io_rdata = wdtcsr;
		A_EECR:   io_rdata = eecr;
		A_EEDR:   io_rdata = eedr;
		A_EEARL:  io_rdata = eear[7:0];
		A_EEARH:  io_rdata = {5'd0, eear[10:8]};
		A_OCR2A:  io_rdata = ocr2a;
		A_SPCR:   io_rdata = spcr;
		A_SPSR:   io_rdata = spsr;
		A_SPDR:   io_rdata = spdr_rx;
		A_SPMCSR: io_rdata = spmcsr;
		A_UCSR0A: io_rdata = ucsr0a;
		A_UCSR0B: io_rdata = ucsr0b;
		A_UCSR0C: io_rdata = ucsr0c;
		A_UBRR0L: io_rdata = ubrr0[7:0];
		A_UBRR0H: io_rdata = {4'd0, ubrr0[11:8]};
		A_UDR0:   io_rdata = rq_n != 5'd0 ? rq[rq_rp] : 8'd0;
		default:  io_rdata = gen_q;
	endcase
end

endmodule
