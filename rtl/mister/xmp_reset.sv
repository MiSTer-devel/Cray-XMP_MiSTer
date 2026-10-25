// Host reset requests cross through the I/O clock before reaching the CPU.
// UART BREAK resets the machine while leaving the serial receiver running.
module xmp_reset (
	input wire clk_cpu,
	input wire clk_ios,
	input wire clk_sys,
	input wire host_reset,
	input wire uart_break,

	output reg  reset_cpu,
	output wire reset_ios,
	output wire reset,
	output wire uart_reset
);

	wire uart_break_cpu;
	cdc_bit sync_break (
		.clk(clk_cpu),
		.d  (uart_break),
		.q  (uart_break_cpu)
	);

	reg  host_reset_ios;
	wire host_reset_cpu;
	always @(posedge clk_ios) host_reset_ios <= host_reset;
	cdc_bit sync_host_reset (
		.clk(clk_cpu),
		.d  (host_reset_ios),
		.q  (host_reset_cpu)
	);

	reg        uart_reset_cpu;
	reg [15:0] reset_cnt;

	always @(posedge clk_cpu) begin
		uart_reset_cpu <= host_reset_cpu;
		if (host_reset_cpu | uart_break_cpu) begin
			reset_cpu <= 1;
			reset_cnt <= '1;
		end else if (reset_cnt != 0) reset_cnt <= reset_cnt - 1'd1;
		else reset_cpu <= 0;
	end

	cdc_bit sync_reset_ios (
		.clk(clk_ios),
		.d  (reset_cpu),
		.q  (reset_ios)
	);

	cdc_bit sync_reset (
		.clk(clk_sys),
		.d  (reset_cpu),
		.q  (reset)
	);
	cdc_bit sync_uart_reset (
		.clk(clk_sys),
		.d  (uart_reset_cpu),
		.q  (uart_reset)
	);

endmodule
