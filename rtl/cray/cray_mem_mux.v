// Memory port multiplexer for the Cray CPU.
//
// N requesters share one memory port that takes requests in a stream and
// answers reads in order (rtl/mister/ddr3_ports.sv has the contract).
// A requester presents req with we, len, addr and wdata; the request is
// taken in a clock where take is high, into a register here, and goes out
// to memory from there: what the requesters ask for late in a clock so does
// not have to reach memory in that clock, and whether a request is taken is
// settled here, from what was known when the clock began.  ack is a
// one-clock pulse per word of a read, with rdata in the same clock; the
// words come back in the order the reads were taken.  A write is done with
// its take.
//
// A requester that streams (STREAM[n] = 1) presents its next request in the
// clock after take.  Any other holds its request until the last ack of its
// read, or until the ack a write is given the clock after take, and is
// looked at again from the clock after that ack.
//
// Priority rotates behind the requester taken last, so the instruction
// buffers cannot starve data references or the reverse: a fetch takes its
// turn between two words of a vector store.
//
// Requester 0 may say a clock ahead what it is going to read (i_early with
// i_early_addr, the length that of its request): it is taken in that clock
// if nobody asks for anything then, and otherwise its request, which it
// presents from the next clock on in any case, takes its turn.  So a fetch
// loses no clock to the register here when the ports are quiet, and what is
// known late about a fetch decides nothing about the others' requests.

module cray_mem_mux #(
	parameter         N      = 2,
	parameter [N-1:0] STREAM = {N{1'b0}}
) (
	input wire clk,
	input wire rst,

	input  wire [   N-1:0] i_req,
	input  wire [   N-1:0] i_we,
	input  wire [ N*7-1:0] i_len,
	input  wire [N*22-1:0] i_addr,
	input  wire [N*64-1:0] i_wdata,
	input  wire            i_early,
	input  wire [    21:0] i_early_addr,
	output wire [   N-1:0] o_take,
	output reg  [   N-1:0] o_ack,
	output reg  [    63:0] o_rdata,

	output wire        o_mem_req,
	output reg         o_mem_code,   // the request is requester 0's: the instruction buffers'
	output reg         o_mem_we,
	output reg  [ 6:0] o_mem_len,
	output reg  [21:0] o_mem_addr,
	output reg  [63:0] o_mem_wdata,
	input  wire        i_mem_take,
	input  wire        i_mem_ack,
	input  wire [63:0] i_mem_rdata
);

	localparam RF = 16;  // reads whose words are still to come

	// rotating priority: requesters above the one taken last go first
	reg  [N-1:0] prio;
	reg  [N-1:0] mask;  // holds its request, and has been taken
	wire [N-1:0] ready = i_req & ~mask;
	wire [N-1:0] above = ready & prio;
	wire [N-1:0] pick_from = (|above) ? above : ready;

	reg     [N-1:0] pick;  // lowest set bit of pick_from
	integer         p;
	always @(*) begin
		pick = {N{1'b0}};
		for (p = N - 1; p >= 0; p = p - 1) if (pick_from[p]) pick = {{(N - 1) {1'b0}}, 1'b1} << p;
	end

	// requester 0 ahead of its request: only when nothing is asked
	wire         early = i_early && !(|ready);
	wire [N-1:0] pick_all = pick | {{(N - 1) {1'b0}}, early};

	// what the picked requester asks for, gathered with its bit
	integer        n;
	reg            sel_we;
	reg     [ 6:0] sel_len;
	reg     [21:0] sel_addr;
	reg     [63:0] sel_wdata;
	always @(*) begin
		sel_we    = 1'b0;
		sel_len   = {7{early}} & i_len[6:0];
		sel_addr  = {22{early}} & i_early_addr;
		sel_wdata = 64'd0;
		for (n = 0; n < N; n = n + 1) begin
			sel_we    = sel_we | (pick[n] & i_we[n]);
			sel_len   = sel_len | ({7{pick[n]}} & i_len[n*7+:7]);
			sel_addr  = sel_addr | ({22{pick[n]}} & i_addr[n*22+:22]);
			sel_wdata = sel_wdata | ({64{pick[n]}} & i_wdata[n*64+:64]);
		end
	end

	// The reads taken and not yet answered, in order: whose, and how many
	// words.  The place at the end of the list is written in every clock that
	// has one, with what is asked for then, and counts when a read is taken:
	// the take, which comes late, stays off the memory's write enable.
	(* ramstyle = "MLAB, no_rw_check" *)reg  [N+6:0] rf          [0:RF-1];
	wire [N-1:0] rf_owner_rd;
	wire [  6:0] rf_len_rd;
	reg [$clog2(RF)-1:0] rf_wr, rf_rd;
	reg  [$clog2(RF):0] rf_n;
	reg  [         6:0] rf_cnt;
	wire                rf_room = (rf_n != RF[$clog2(RF):0]);

	// The request for memory stands in a register until memory takes it, and
	// one more can stand behind it: a requester's request is taken when that
	// second place is free, which is known from the start of the clock.  So
	// whether memory takes a request in a clock decides nothing about the
	// requesters in that clock, and memory sees the requests no later than it
	// would with one register that is filled as it is emptied.
	localparam WO = 1 + 1 + 7 + 22 + 64;
	reg           out_v;
	reg           held_v;  // the second place holds a request
	reg  [WO-1:0] held;
	wire [WO-1:0] sel = {pick_all[0], sel_we, sel_len, sel_addr, sel_wdata};
	wire          out_free = !out_v || i_mem_take;
	wire          sel_ok = (|pick) && (sel_we || rf_room);
	wire          early_ok = early && rf_room;
	wire          taken = sel_ok && !held_v;
	wire          early_taken = early_ok && !held_v;
	wire          taken_any = taken || early_taken;
	assign o_take    = pick & {N{taken}};
	assign o_mem_req = out_v;
	// (the second place is written whenever it is empty, with what is asked
	// for then: only its flag says whether that is a request it holds)
	always @(posedge clk) if (!held_v) held <= sel;
	always @(posedge clk)
		if (rst) begin
			out_v  <= 1'b0;
			held_v <= 1'b0;
		end else if (out_free) begin
			out_v                                                      <= held_v || taken_any;
			held_v                                                     <= 1'b0;
			{o_mem_code, o_mem_we, o_mem_len, o_mem_addr, o_mem_wdata} <= held_v ? held : sel;
		end else if (taken_any) held_v <= 1'b1;

	assign {rf_owner_rd, rf_len_rd} = rf[rf_rd];
	wire         rf_pop = i_mem_ack && (rf_n != 0) && (rf_cnt + 7'd1 == rf_len_rd);
	reg  [N-1:0] ack_last;

	always @(posedge clk) if (rf_room) rf[rf_wr] <= {pick_all, sel_len};

	always @(posedge clk) begin
		o_ack    <= {N{1'b0}};
		ack_last <= {N{1'b0}};

		if (rst) begin
			prio   <= {N{1'b0}};
			mask   <= {N{1'b0}};
			rf_wr  <= {$clog2(RF) {1'b0}};
			rf_rd  <= {$clog2(RF) {1'b0}};
			rf_n   <= {($clog2(RF) + 1) {1'b0}};
			rf_cnt <= 7'd0;
		end else begin
			if (taken_any) begin
				for (n = 0; n < N; n = n + 1) if (pick_all[n]) prio <= ~((({{(N - 1) {1'b0}}, 1'b1} << n) << 1) - 1'b1);
				if (!sel_we) rf_wr <= rf_wr + 1'd1;
			end
			rf_n <= rf_n + {{$clog2(RF) {1'b0}}, taken_any && !sel_we} - {{$clog2(RF) {1'b0}}, rf_pop};

			// a word read: to the requester whose read is the oldest
			if (i_mem_ack && (rf_n != 0)) begin
				o_rdata <= i_mem_rdata;
				o_ack   <= rf_owner_rd;
				rf_cnt  <= rf_pop ? 7'd0 : rf_cnt + 7'd1;
				if (rf_pop) begin
					rf_rd    <= rf_rd + 1'd1;
					ack_last <= rf_owner_rd;
				end
			end

			// requesters that hold their request until its acknowledge
			for (n = 0; n < N; n = n + 1)
			if (!STREAM[n]) begin
				if (o_take[n]) begin
					mask[n] <= 1'b1;
					if (i_we[n]) begin
						o_ack[n]    <= 1'b1;
						ack_last[n] <= 1'b1;
					end
				end
				if (o_ack[n] && ack_last[n]) mask[n] <= 1'b0;
			end
			// (taken ahead of its request, requester 0's request is not taken again)
			if (early_taken) mask[0] <= 1'b1;
		end
	end

endmodule
