// Console and printer streams cross from clk_ios into the display clock.
// reset_core resets terminal state at a frame boundary; the raster keeps running.
module xmp_frontend #(
	parameter CLK_HZ = 58800000
) (
	input wire clk_sys,
	input wire clk_ios,
	input wire reset,
	input wire reset_ios,
	input wire reset_core,
	input wire uart_reset,

	input wire boot_missing,
	input wire boot_done,

	input  wire [41:0] char,
	input  wire [ 5:0] char_valid,
	output wire [ 5:0] char_ready,
	output wire [41:0] key,
	output wire [ 5:0] key_valid,
	input  wire [ 5:0] key_ready,

	input  wire [7:0] print_char,
	input  wire       print_valid,
	output wire       print_ready,

	input wire [10:0] ps2_key,
	input wire        font_8x8,
	input wire [ 1:0] col,

	input  wire uart_rxd,
	output wire uart_txd,
	output wire uart_break,

	output reg         ce_pix,
	output wire        hvcnt_atzero,
	output wire        hblank,
	output wire        hsync,
	output wire        vblank,
	output wire        vsync,
	output wire [23:0] video,
	output wire [15:0] audio
);

	localparam OPERATOR = 3;
	localparam STATION  = 0;

	assign char_ready[1] = 1'b1;
	assign char_ready[2] = 1'b1;
	assign char_ready[4] = 1'b1;
	assign char_ready[5] = 1'b1;
	assign key_valid[1]  = 1'b0;
	assign key_valid[2]  = 1'b0;
	assign key_valid[4]  = 1'b0;
	assign key_valid[5]  = 1'b0;
	assign key[13:7]     = 7'd0;
	assign key[20:14]    = 7'd0;
	assign key[41:28]    = 14'd0;

	wire [13:0] con_tx_data, con_rx_data, term_data;
	wire [1:0] con_tx_valid, con_tx_ready, con_rx_valid, con_rx_ready, term_valid, term_ready;

	cdc_stream #(
		.W(7)
	) operator_tx (
		.src_clk  (clk_ios),
		.src_reset(reset_ios),
		.src_data (char[7*OPERATOR+:7]),
		.src_valid(char_valid[OPERATOR]),
		.src_ready(char_ready[OPERATOR]),
		.dst_clk  (clk_sys),
		.dst_reset(reset),
		.dst_data (con_tx_data[6:0]),
		.dst_valid(con_tx_valid[0]),
		.dst_ready(con_tx_ready[0])
	);

	cdc_stream #(
		.W(7)
	) station_tx (
		.src_clk  (clk_ios),
		.src_reset(reset_ios),
		.src_data (char[7*STATION+:7]),
		.src_valid(char_valid[STATION]),
		.src_ready(char_ready[STATION]),
		.dst_clk  (clk_sys),
		.dst_reset(reset),
		.dst_data (con_tx_data[13:7]),
		.dst_valid(con_tx_valid[1]),
		.dst_ready(con_tx_ready[1])
	);

	cdc_stream #(
		.W(7)
	) operator_rx (
		.src_clk  (clk_sys),
		.src_reset(reset),
		.src_data (con_rx_data[6:0]),
		.src_valid(con_rx_valid[0]),
		.src_ready(con_rx_ready[0]),
		.dst_clk  (clk_ios),
		.dst_reset(reset_ios),
		.dst_data (key[7*OPERATOR+:7]),
		.dst_valid(key_valid[OPERATOR]),
		.dst_ready(key_ready[OPERATOR])
	);

	cdc_stream #(
		.W(7)
	) station_rx (
		.src_clk  (clk_sys),
		.src_reset(reset),
		.src_data (con_rx_data[13:7]),
		.src_valid(con_rx_valid[1]),
		.src_ready(con_rx_ready[1]),
		.dst_clk  (clk_ios),
		.dst_reset(reset_ios),
		.dst_data (key[7*STATION+:7]),
		.dst_valid(key_valid[STATION]),
		.dst_ready(key_ready[STATION])
	);

	reg [ 2:0] key_tgl;
	reg [10:0] ps2_key_s = 0;
	always @(posedge clk_sys) begin
		key_tgl <= {key_tgl[1:0], ps2_key[10]};
		if (key_tgl[2] != key_tgl[1]) ps2_key_s <= {~ps2_key_s[10], ps2_key[9:0]};
	end

	reg [1:0] visible;
	reg       key_stb;
	always @(posedge clk_sys) begin
		key_stb <= ps2_key_s[10];
		if (reset) visible <= 2'd0;
		else if (key_stb != ps2_key_s[10] && ps2_key_s[9:8] == 2'b10) begin
			if (ps2_key_s[7:0] == 8'h05) visible <= 2'd0;
			if (ps2_key_s[7:0] == 8'h06) visible <= 2'd1;
			if (ps2_key_s[7:0] == 8'h04) visible <= 2'd2;
		end
	end

	wire [6:0] shown_char, prt_data;
	wire shown_valid, shown_taken, prt_valid, prt_ready;

	print_screen print_screen (
		.clk  (clk_ios),
		.reset(reset_ios),

		.i_char (print_char),
		.i_valid(print_valid),
		.o_ready(print_ready),

		.o_char (shown_char),
		.o_valid(shown_valid),
		.i_ready(shown_taken)
	);

	cdc_stream #(
		.W(7)
	) printer_tx (
		.src_clk  (clk_ios),
		.src_reset(reset_ios),
		.src_data (shown_char),
		.src_valid(shown_valid),
		.src_ready(shown_taken),
		.dst_clk  (clk_sys),
		.dst_reset(reset),
		.dst_data (prt_data),
		.dst_valid(prt_valid),
		.dst_ready(prt_ready)
	);

	wire no_file, started;
	cdc_bit sync_no_file (
		.clk(clk_sys),
		.d  (boot_missing),
		.q  (no_file)
	);
	cdc_bit sync_started (
		.clk(clk_sys),
		.d  (boot_done),
		.q  (started)
	);

	wire [7:0] kbd_data;
	wire kbd_valid, kbd_ready;

	wire [13:0] sent_data;
	wire [1:0] sent_valid, sent_ready;

	term_keyboard #(
		.CAPS(1)
	) keyboard (
		.clk       (clk_sys),
		.reset     (reset),
		.ps2_key   (ps2_key_s),
		.dout      (kbd_data),
		.dout_valid(kbd_valid),
		.dout_ready(kbd_ready)
	);

	xmp_console #(
		.CLK_HZ(CLK_HZ),
		.BAUD  (115200)
	) console (
		.clk       (clk_sys),
		.reset     (reset),
		.uart_reset(uart_reset),

		.no_file(no_file),
		.started(started),

		.tx_data (con_tx_data),
		.tx_valid(con_tx_valid),
		.tx_ready(con_tx_ready),
		.rx_data (con_rx_data),
		.rx_valid(con_rx_valid),
		.rx_ready(con_rx_ready),

		.term_data (term_data),
		.term_valid(term_valid),
		.term_ready(term_ready),

		.key_data (sent_data),
		.key_valid(sent_valid),
		.key_ready(sent_ready),

		.uart_rxd  (uart_rxd),
		.uart_txd  (uart_txd),
		.uart_break(uart_break)
	);

	wire pixel, half, bell;

	xmp_terminal terminal (
		.clk  (clk_sys),
		.reset(reset_core),

		.ce_pix      (ce_pix),
		.hvcnt_atzero(hvcnt_atzero),

		.hblank(hblank),
		.hsync (hsync),
		.vblank(vblank),
		.vsync (vsync),

		.video(pixel),

		.font_8x8(font_8x8),
		.visible (visible),

		.rx_data ({prt_data, term_data}),
		.rx_valid({prt_valid, term_valid}),
		.rx_ready({prt_ready, term_ready}),

		.key_data (kbd_data),
		.key_valid(kbd_valid),
		.key_ready(kbd_ready),

		.tx_data (sent_data),
		.tx_valid(sent_valid),
		.tx_ready(sent_ready),

		.half(half),
		.bell(bell)
	);

	always @(posedge clk_sys) begin
		reg [1:0] div;
		div    <= div + 2'd1;
		ce_pix <= font_8x8 ? (div == 2'd0) : ~div[0];
	end

	localparam [14:0] BELL_HALF = 15'(CLK_HZ / 2000 - 1);
	reg        bell_tone;
	reg [14:0] bell_div;
	always @(posedge clk_sys)
		if (!bell) begin
			bell_tone <= 1'b0;
			bell_div  <= 15'd0;
		end else if (bell_div == BELL_HALF) begin
			bell_tone <= ~bell_tone;
			bell_div  <= 15'd0;
		end else bell_div <= bell_div + 15'd1;

	assign audio = {3'd0, bell_tone, 12'd0};

	reg [23:0] rgb;
	always @(*) begin
		case (col)
			2'd0: rgb = 24'hFFFFFF;
			2'd1: rgb = 24'h33FF33;
			2'd2: rgb = 24'hFFB000;
			2'd3: rgb = 24'h40FFFF;
		endcase
	end

	assign video = !pixel ? 24'd0 : half ? {1'b0, rgb[23:17], 1'b0, rgb[15:9], 1'b0, rgb[7:1]} : rgb;

endmodule
