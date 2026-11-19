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
//   - all other registers (timer 0 / 2, SPI, USART, ...) read back what was written (SPI / USART later).
// IO index = data address - 0x20. Interrupt vectors (word addresses): WDT 0x10, TIMER1_COMPA 0x1A,
// TIMER1_COMPB 0x1C, TIMER1_OVF 0x1E.

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
	output            sample        // OCR2A written while timer 2 runs
);

localparam A_PINA = 8'h00, A_DDRA = 8'h01, A_PORTA = 8'h02, A_PINB = 8'h03, A_DDRB = 8'h04, A_PORTB = 8'h05,
           A_PINC = 8'h06, A_DDRC = 8'h07, A_PORTC = 8'h08, A_PIND = 8'h09, A_DDRD = 8'h0A, A_PORTD = 8'h0B,
           A_TIFR1 = 8'h16, A_EECR = 8'h1F, A_EEDR = 8'h20, A_EEARL = 8'h21, A_EEARH = 8'h22,
           A_WDTCSR = 8'h40, A_TIMSK1 = 8'h4F, A_TCCR1B = 8'h61, A_TCNT1L = 8'h64, A_TCNT1H = 8'h65,
           A_OCR1AL = 8'h68, A_OCR1AH = 8'h69, A_OCR1BL = 8'h6A, A_OCR1BH = 8'h6B,
           A_TCCR2B = 8'h91, A_OCR2A = 8'h93;
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
assign irq = irq_wdt | irq_t1a | irq_t1b | irq_t1o;
always @* begin
	if (irq_wdt)      irq_vec = 6'h10;
	else if (irq_t1a) irq_vec = 6'h1A;
	else if (irq_t1b) irq_vec = 6'h1C;
	else              irq_vec = 6'h1E;
end
wire [7:0] t1_ack = (irq_ack && !irq_wdt) ? (irq_t1a ? 8'h02 : irq_t1b ? 8'h04 : 8'h01) : 8'h00;
wire [7:0] t1_clr = (wr && io_addr == A_TIFR1) ? (bitop ? (io_wdata & io_bitmask) : io_wdata) : 8'h00;

always @(posedge clk) begin
	if (rst) begin
		tcnt1 <= 16'd0; temp <= 8'd0; tccr1b <= 8'd0; ocr1a <= 16'd0; ocr1b <= 16'd0; timsk1 <= 8'd0;
		tifr1 <= 8'd0; t1_ev <= 3'd0;
	end else begin
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
reg  [19:0] wdt_acc;     // cycles since the last instruction end
reg  [19:0] wdt_cnt /* verilator public_flat */;
wire [7:0]  wdtcsr_e = (wr && io_addr == A_WDTCSR) ? io_wdata : wdtcsr;
wire [19:0] wdt_base = wdr ? 20'd0 : wdt_cnt;
wire [20:0] wdt_sum  = {1'b0, wdt_base} + {1'b0, wdt_acc} + 21'd1;
always @(posedge clk) begin
	if (rst) begin
		wdtcsr <= 8'd0; wdt_acc <= 20'd0; wdt_cnt <= 20'd0;
	end else begin
		if (wr && io_addr == A_WDTCSR) wdtcsr <= io_wdata;
		if (irq_ack && irq_wdt) wdtcsr[7] <= 1'b0;
		if (insn_end) begin
			wdt_acc <= 20'd0;
			if (wdtcsr_e[3]) begin
				if (wdt_sum >= {1'b0, WDT_CYCLES} && wdtcsr_e[6]) begin
					wdtcsr[7] <= 1'b1; wdt_cnt <= 20'd0;
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
assign halt = ee_halt != 3'd0;
always @(posedge clk) begin
	if (rst) begin
		eecr <= 8'd0; eedr <= 8'd0; eear <= 11'd0; ee_halt <= 3'd0; ee_rd <= 1'b0; ee_wr <= 1'b0;
	end else begin
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
		default:  io_rdata = gen_q;
	endcase
end

endmodule
