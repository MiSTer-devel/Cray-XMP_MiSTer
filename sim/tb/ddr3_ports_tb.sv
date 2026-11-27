// The port to DDR3 (rtl/mister/ddr3_ports.sv) by itself, with five users as
// the core has them: user 0 streams its requests, the others hold theirs.
module ddr3_ports_tb #(
	parameter LINES = 1024
) (
	input wire clk,
	input wire reset,

	input  wire [  4:0] req,
	input  wire [  4:0] we,
	input  wire [  4:0] code,
	input  wire [ 34:0] len,
	input  wire [124:0] addr,
	input  wire [319:0] wdata,
	input  wire [  4:0] user_rst,
	output wire [  4:0] take,
	output wire         free0,
	output wire [  4:0] ack,
	output wire [ 63:0] rdata,

	input  wire        DDRAM_BUSY,
	output wire [ 7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire [ 7:0] DDRAM_BE,
	output wire        DDRAM_WE
);

	wire unused_clk;
	ddr3_ports #(
		.N     (5),
		.STREAM(5'b00001),
		.LINES (LINES)
	) dut (
		.clk             (clk),
		.reset           (reset),
		.req             (req),
		.we              (we),
		.code            (code),
		.len             (len),
		.addr            (addr),
		.wdata           (wdata),
		.user_rst        (user_rst),
		.take            (take),
		.free0           (free0),
		.ack             (ack),
		.rdata           (rdata),
		.DDRAM_CLK       (unused_clk),
		.DDRAM_BUSY      (DDRAM_BUSY),
		.DDRAM_BURSTCNT  (DDRAM_BURSTCNT),
		.DDRAM_ADDR      (DDRAM_ADDR),
		.DDRAM_DOUT      (DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD        (DDRAM_RD),
		.DDRAM_DIN       (DDRAM_DIN),
		.DDRAM_BE        (DDRAM_BE),
		.DDRAM_WE        (DDRAM_WE)
	);

endmodule
