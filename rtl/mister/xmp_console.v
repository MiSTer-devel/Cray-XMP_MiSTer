// Console plumbing of the CRAY X-MP core, in the clock domain of the video.
//
// There are two consoles: 0 is the operator's console of the I/O Subsystem,
// 1 the station.  What they print goes to their screens, and what a terminal
// sends, the keys typed at it and its answers, goes to its console.
//
// The station is also on the HPS serial port, as a terminal on a line of its
// own would be: 9,600 baud, eight bits, no parity, the speed of the consoles'
// lines.  What the station prints goes out there as it goes to the screen,
// and a byte that comes in is typed at the station.  The port keeps the pace
// only while somebody listens: with Clear To Send from the HPS, which Linux
// raises while a program has the port open, a character waits for the port;
// without it nothing is sent and the screen does not wait.  Request To Send
// tells the HPS when the queue of what came in is half full.  Both are low
// when they say yes, as the framework has them.
//
// The core's own two messages are put on the operator's console the same way
// the machine's characters are: `no_file` when there is no boot file to start
// from, `started` when the I/O Subsystem has been dead started.  Each is sent
// once, when its signal rises; the machine is in reset or has not printed
// anything yet at those times.

module xmp_console #(
	parameter CLK_HZ = 29400000,
	parameter BAUD   = 9600
) (
	input wire clk,
	input wire reset,

	input wire no_file,
	input wire started,

	// what the machine prints
	input  wire [13:0] tx_data,
	input  wire [ 1:0] tx_valid,
	output wire [ 1:0] tx_ready,

	// keys for the machine
	output wire [13:0] rx_data,
	output wire [ 1:0] rx_valid,
	input  wire [ 1:0] rx_ready,

	// the screens
	output wire [13:0] term_data  /* verilator public_flat_rd */,
	output wire [ 1:0] term_valid  /* verilator public_flat_rd */,
	input  wire [ 1:0] term_ready,

	// what the terminals send
	input  wire [13:0] key_data,
	input  wire [ 1:0] key_valid,
	output wire [ 1:0] key_ready,

	// HPS serial port: the station's line
	input  wire uart_rxd,
	output wire uart_txd,
	input  wire uart_cts_n,
	output wire uart_rts_n
);

	// ---- the core's messages ----
	// 64 characters each, the text first and zeros after it
	localparam [511:0] NO_FILE_TEXT = {
		8'h1B, "*CRAY X-MP", 8'h0D, 8'h0A, 8'h0A, "Load a boot file from the menu to start it.", 8'h0D, 8'h0A, 40'd0
	};
	localparam [511:0] STARTED_TEXT = {"I/O SUBSYSTEM DEAD START", 8'h0D, 8'h0A, 304'd0};

	reg no_file_d, started_d;
	reg msg_on, msg_which;
	reg  [5:0] msg_n;  // the character to send
	wire [8:0] msg_bit = {~msg_n, 3'd0};
	wire [6:0] msg_char = msg_which ? STARTED_TEXT[msg_bit+:7] : NO_FILE_TEXT[msg_bit+:7];
	wire       msg_taken;

	always @(posedge clk) begin
		no_file_d <= no_file;
		started_d <= started;
		if (reset) begin
			msg_on    <= 1'b0;
			no_file_d <= 1'b0;
			started_d <= 1'b0;
		end else if (msg_on) begin
			if (msg_char == 7'd0) msg_on <= 1'b0;
			else if (msg_taken) msg_n <= msg_n + 6'd1;
		end else if (no_file && !no_file_d) begin
			msg_on    <= 1'b1;
			msg_which <= 1'b0;
			msg_n     <= 6'd0;
		end else if (started && !started_d) begin
			msg_on    <= 1'b1;
			msg_which <= 1'b1;
			msg_n     <= 6'd0;
		end
	end

	// ---- output: a character goes to its screen when the screen can take it,
	// and the station's to the serial port as well while somebody listens ----
	wire [6:0] out0 = msg_on ? msg_char : tx_data[6:0];
	wire       valid0 = msg_on ? (msg_char != 7'd0) : tx_valid[0];
	wire       took0 = valid0 && term_ready[0];

	reg [1:0] cts;
	always @(posedge clk) cts <= {cts[0], ~uart_cts_n};
	wire listening = cts[1];
	wire uart_ready;
	wire took1 = tx_valid[1] && term_ready[1] && (!listening || uart_ready);

	assign term_data  = {tx_data[13:7], out0};
	assign term_valid = {took1, took0};
	assign tx_ready   = {took1, took0 & ~msg_on};
	assign msg_taken  = took0 & msg_on;

	uart_tx #(
		.CLK_HZ(CLK_HZ),
		.BAUD  (BAUD)
	) utx (
		.clk      (clk),
		.reset    (reset),
		.din      ({1'b0, tx_data[13:7]}),
		.din_valid(took1 && listening),
		.din_ready(uart_ready),
		.txd      (uart_txd)
	);

	// ---- input: what a terminal sends waits for room; a byte of the serial
	// port cannot wait, so it goes first ----
	wire [7:0] ser_data;
	wire       ser_valid;

	uart_rx #(
		.CLK_HZ(CLK_HZ),
		.BAUD  (BAUD)
	) urx (
		.clk       (clk),
		.reset     (reset),
		.rxd       (uart_rxd),
		.dout      (ser_data),
		.dout_valid(ser_valid),
		.brk       ()
	);

	// a few characters for the operator's console, whose terminal waits
	wire full0;
	assign key_ready[0] = !full0;
	con_fifo #(
		.AW(2),
		.DW(7)
	) keys0 (
		.clk  (clk),
		.reset(reset),
		.din  (key_data[6:0]),
		.wr   (key_valid[0]),
		.full (full0),
		.half (),
		.dout (rx_data[6:0]),
		.valid(rx_valid[0]),
		.rd   (rx_ready[0])
	);

	// sixteen for the station, half of them room for what the serial port
	// still brings after it has been told to stop
	wire full1;
	assign key_ready[1] = !full1 && !ser_valid;
	con_fifo #(
		.AW(4),
		.DW(7)
	) keys1 (
		.clk  (clk),
		.reset(reset),
		.din  (ser_valid ? ser_data[6:0] : key_data[13:7]),
		.wr   (ser_valid || key_valid[1]),
		.full (full1),
		.half (uart_rts_n),
		.dout (rx_data[13:7]),
		.valid(rx_valid[1]),
		.rd   (rx_ready[1])
	);

endmodule
