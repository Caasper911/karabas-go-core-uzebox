// uze_wb_ram_sim.v - simulation stand-in for uze_sdram (the controller itself runs on the boards in
// core-doom / core-agon): the same wishbone slave, 1 MB, about its latency: a single access is acked
// 6 clocks after the request, a burst (cti 010) acks 8 words of its 32-byte line, one every 2 clocks
// after 7; a request is taken only between transactions (as S_IDLE of uze_sdram).
// karabas-go-core-uzebox, GPL-3.0-or-later.

module uze_wb_ram_sim (
	input             clk,
	input             reset,
	output            ready,
	input             wb_cyc,
	input             wb_stb,
	input             wb_we,
	input      [3:0]  wb_sel,
	input      [24:2] wb_adr,
	input      [2:0]  wb_cti,
	input      [31:0] wb_dat_i,
	output reg [31:0] wb_dat_o,
	output reg        wb_ack
);

reg [31:0] mem [0:262143];
reg [7:0]  cnt = 8'd0;
reg        busy = 1'b0;
reg        burst = 1'b0;
reg        we = 1'b0;
reg [17:0] a = 18'd0;
reg [3:0]  n = 4'd0;
reg [31:0] d = 32'd0;
reg [3:0]  sel = 4'd0;
reg [3:0]  rst_cnt = 4'd0;
assign ready = rst_cnt == 4'd15;

always @(posedge clk) begin
	wb_ack <= 1'b0;
	if (reset) begin busy <= 1'b0; rst_cnt <= 4'd0; end
	else begin
		if (rst_cnt != 4'd15) rst_cnt <= rst_cnt + 4'd1;
		if (!busy) begin
			if (wb_cyc && wb_stb && !wb_ack) begin
				busy <= 1'b1; burst <= wb_cti == 3'b010; we <= wb_we; a <= wb_adr[19:2]; d <= wb_dat_i;
				sel <= wb_sel; n <= 4'd0; cnt <= 8'd0;
			end
		end else begin
			cnt <= cnt + 8'd1;
			if (we) begin
				if (cnt == 8'd5) begin
					if (sel[0]) mem[a][7:0] <= d[7:0];
					if (sel[1]) mem[a][15:8] <= d[15:8];
					if (sel[2]) mem[a][23:16] <= d[23:16];
					if (sel[3]) mem[a][31:24] <= d[31:24];
					wb_ack <= 1'b1;
				end
				if (cnt == 8'd8) busy <= 1'b0;
			end else if (!burst) begin
				if (cnt == 8'd5) begin wb_dat_o <= mem[a]; wb_ack <= 1'b1; end
				if (cnt == 8'd8) busy <= 1'b0;
			end else begin
				if (cnt >= 8'd7 && cnt[0] && n != 4'd8) begin
					wb_dat_o <= mem[{a[17:3], a[2:0] + n[2:0]}]; wb_ack <= 1'b1; n <= n + 4'd1;
				end
				if (cnt == 8'd26) busy <= 1'b0;
			end
		end
	end
end

endmodule
