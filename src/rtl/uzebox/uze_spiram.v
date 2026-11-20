// uze_spiram.v - the SPI RAM of the Uzebox (Microchip 23LC1024, 128 KB, CS = PA4), emulated in the board
// SDRAM (byte 0x100000 + address, through uze_fb).
//
// It works on the bytes of the SPI master of the CPU (avr_io_m644 spi_start / spi_done), not on the pins: a
// byte is taken at the START of its transfer (the master knows it then), the byte the RAM sends goes into SPDR
// at the END. The kernel reads SPDR a fixed 17 clocks after its write (spiram.s, fosc / 2): after the last
// address byte it has ~34 clocks (1.2 us) until the data byte is taken; an SDRAM read takes ~0.7 us at worst.
// Commands: 03 READ, 02 WRITE (24-bit address, 17 bits used), 05 RDMR, 01 WRMR; modes 00 byte, 80 page (32
// bytes), 40 sequential (the default). Reads go through a one-word cache, the next word is fetched as soon as
// the current one is taken; writes go through a 4-entry queue (a byte every 16 clocks at most) and update the
// cache. Any other command: the RAM sends FF until CS goes high.
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uze_spiram (
	input             clk,
	input             rst,

	input             cs_n,
	input             spi_start,
	input      [7:0]  spi_tx,
	input             spi_done,
	output     [7:0]  rx,            // the byte for SPDR, taken by the master at spi_done (combinational)
	output            late,          // debug: a read byte was not there at spi_done

	// the SDRAM (uze_fb, clk_sdr): a toggle per request, held until its ack toggles back
	output reg        m_req_tg,
	output reg        m_we,
	output reg [14:0] m_word,
	output reg [1:0]  m_lane,
	output reg [7:0]  m_byte,
	input             m_ack_tg,
	input      [31:0] m_rdata
);

localparam S_CMD = 3'd0, S_A2 = 3'd1, S_A1 = 3'd2, S_A0 = 3'd3, S_READ = 3'd4, S_WRITE = 3'd5, S_MODE = 3'd6,
           S_SKIP = 3'd7;

reg [2:0]  state = S_CMD;
reg        rd = 1'b0;
reg        rdmr = 1'b0;              // this transfer sends the mode
reg        rdmr_pend = 1'b0;         // the next one does (after an RDMR command)
reg [7:0]  mode = 8'h40;
reg [16:0] addr = 17'd0;             // the next byte of the read / write
reg [16:0] out_addr = 17'd0;         // the byte this transfer sends
reg        out_want = 1'b0;          // this transfer sends out_addr
reg        out_ok = 1'b0;
reg [7:0]  out_byte = 8'hFF;
reg        late_r /* verilator public_flat */ = 1'b0;
assign late = late_r;

// one-word read cache
reg [31:0] cw = 32'd0;
reg [14:0] cw_a = 15'd0;
reg        cw_v = 1'b0;

// requests: a 4-entry write queue, then a read of word(addr) when it is not cached
reg [24:0] wq [0:3];                 // { word, lane, byte }
reg [1:0]  wq_rd = 2'd0, wq_wr = 2'd0;
reg [2:0]  wq_n = 3'd0;
reg        busy = 1'b0;              // a request is out
reg        busy_rd = 1'b0;
reg [2:0]  ack_s = 3'd0;
wire       ack = ack_s[2] ^ ack_s[1];

function [16:0] next_addr;
	input [16:0] a;
	input [7:0]  m;
	begin
		if (m[7:6] == 2'b00) next_addr = a;                       // byte mode
		else if (m[7:6] == 2'b10) next_addr = {a[16:5], a[4:0] + 5'd1};   // page
		else next_addr = a + 17'd1;                               // sequential
	end
endfunction

function [7:0] lane_of;
	input [31:0] w;
	input [1:0]  l;
	begin
		lane_of = (l == 2'd0) ? w[7:0] : (l == 2'd1) ? w[15:8] : (l == 2'd2) ? w[23:16] : w[31:24];
	end
endfunction

initial begin m_req_tg = 1'b0; m_we = 1'b0; m_word = 15'd0; m_lane = 2'd0; m_byte = 8'd0; end
assign rx = rdmr ? mode : (out_want ? (out_ok ? out_byte : lane_of(cw, out_addr[1:0])) : 8'hFF);

always @(posedge clk) begin
	ack_s <= {ack_s[1:0], m_ack_tg};
	if (rst) begin
		state <= S_CMD; mode <= 8'h40; cw_v <= 1'b0; wq_n <= 3'd0; wq_rd <= 2'd0; wq_wr <= 2'd0; busy <= 1'b0;
		out_want <= 1'b0; late_r <= 1'b0;
	end else begin
		// ---- the end of a request
		if (busy && ack) begin
			busy <= 1'b0;
			if (busy_rd) begin cw <= m_rdata; cw_a <= m_word; cw_v <= 1'b1; end
		end

		// ---- the byte of the current read transfer
		if (out_want && !out_ok && cw_v && cw_a == out_addr[16:2]) begin
			out_byte <= lane_of(cw, out_addr[1:0]); out_ok <= 1'b1;
		end

		// ---- CS high: back to a command (the kernel deselects between its accesses)
		if (cs_n) begin state <= S_CMD; rdmr_pend <= 1'b0; end

		// ---- a byte from the master
		if (spi_start) begin
			out_want <= 1'b0; out_ok <= 1'b0; out_byte <= 8'hFF; rdmr <= rdmr_pend && !cs_n; rdmr_pend <= 1'b0;
			if (!cs_n) case (state)
				S_CMD: begin
					rd <= spi_tx == 8'h03;
					if (spi_tx == 8'h03 || spi_tx == 8'h02) state <= S_A2;
					else if (spi_tx == 8'h05) begin rdmr_pend <= 1'b1; state <= S_SKIP; end
					else if (spi_tx == 8'h01) state <= S_MODE;
					else if (spi_tx != 8'hFF) state <= S_SKIP;
				end
				S_A2: begin addr[16] <= spi_tx[0]; state <= S_A1; end
				S_A1: begin addr[15:8] <= spi_tx; state <= S_A0; end
				S_A0: begin addr[7:0] <= spi_tx; state <= rd ? S_READ : S_WRITE; end
				S_READ: begin
					out_want <= 1'b1; out_addr <= addr; addr <= next_addr(addr, mode);
					if (cw_v && cw_a == addr[16:2]) begin out_byte <= lane_of(cw, addr[1:0]); out_ok <= 1'b1; end
				end
				S_WRITE: begin
					wq[wq_wr] <= {addr[16:2], addr[1:0], spi_tx}; wq_wr <= wq_wr + 2'd1;
					if (cw_v && cw_a == addr[16:2]) case (addr[1:0])
						2'd0: cw[7:0] <= spi_tx;
						2'd1: cw[15:8] <= spi_tx;
						2'd2: cw[23:16] <= spi_tx;
						default: cw[31:24] <= spi_tx;
					endcase
					addr <= next_addr(addr, mode);
				end
				S_MODE: begin mode <= spi_tx; state <= S_SKIP; end
				default: ;
			endcase
		end

		// ---- what goes into SPDR
		if (spi_done && out_want && !out_ok) late_r <= 1'b1;

		// ---- the next request: writes first, then the read of word(addr) (or of out_addr)
		if (!busy || (busy && ack)) begin
			if (wq_n != 3'd0 && !(spi_start && state == S_WRITE && !cs_n)) begin
				{m_word, m_lane, m_byte} <= wq[wq_rd]; m_we <= 1'b1; busy_rd <= 1'b0;
				m_req_tg <= ~m_req_tg; busy <= 1'b1; wq_rd <= wq_rd + 2'd1;
			end else if (wq_n == 3'd0 && (state == S_READ || out_want) && !spi_start) begin
				if (out_want && !out_ok && !(cw_v && cw_a == out_addr[16:2])) begin
					m_word <= out_addr[16:2]; m_we <= 1'b0; busy_rd <= 1'b1; m_req_tg <= ~m_req_tg; busy <= 1'b1;
				end else if (state == S_READ && !(cw_v && cw_a == addr[16:2]) && (!out_want || out_ok)) begin
					m_word <= addr[16:2]; m_we <= 1'b0; busy_rd <= 1'b1; m_req_tg <= ~m_req_tg; busy <= 1'b1;
				end
			end
		end
		wq_n <= wq_n + ((spi_start && !cs_n && state == S_WRITE) ? 3'd1 : 3'd0)
		             - (((!busy || (busy && ack)) && wq_n != 3'd0 && !(spi_start && state == S_WRITE && !cs_n)) ? 3'd1 : 3'd0);
	end
end

endmodule
