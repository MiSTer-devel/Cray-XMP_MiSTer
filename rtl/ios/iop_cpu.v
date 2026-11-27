// The I/O Processor of the Cray I/O Subsystem: a 16-bit accumulator machine
// (HR-0030, I/O Subsystem Model B Hardware Reference Manual, sections 3 to 6).
//
// The reference is the model in tools/crates/ios/src/iop.rs, which has the
// page numbers; this module does what that one does, instruction for
// instruction and clock period for clock period, and sim/harness/iop_main.cpp
// checks it against a record of the model's steps.
//
//   A (16 bits) with the carry C as its bit 2**16; B (9 bits); 512 operand
//   registers; P; a program exit stack of 16 locations addressed by E; the
//   System Interrupt Enable flag I.  An instruction is a parcel with f in
//   bits 15 to 9 and d in bits 8 to 0, or two parcels with a constant k.
//
// Time.  An instruction does all it does in the clock it issues in (the word
// an operand in Local Memory, a function that reads or a flag test brings is
// in the accumulator a clock later, a result is stored in Local Memory two
// clocks later).  What the real machine spreads over the clock periods behind
// the issue decides only when the instructions behind it may issue: one
// issues while those before it are still under way if it needs nothing they
// still hold.  docs/spec/iop-cpu-spec.md, part 8.2, has the rules (R1 to
// R13) and where each is from; here every one is a counter that runs down to
// the clock in which the thing is free.
//
// The instruction stack.  Instructions issue from a stack of 32 parcels that
// is filled from Local Memory a parcel a clock, in bursts that end on a
// 4-parcel boundary, while the last parcel asked for is fewer than 8 ahead of
// the instruction that issues next.  A parcel can issue 4 clocks after it is
// read.  A branch by P and d to an instruction the stack holds takes 5 clock
// periods; any other one, an EXIT and an interrupt fill the stack again from
// the new P: the first parcel is read in the clock behind the fetch request
// and issues 5 behind it.  The processor has one port into Local Memory: in
// the clocks an instruction reads its operand or stores its result there, no
// parcel is read for the stack.
//
// An instruction that issues is what Local Memory holds then.  A store of the
// processor into a parcel the stack holds, and a channel's (i_store), make
// the stack fill again: from behind the storing instruction, or from P.
//
// In front of the issue stands the instruction (ir), taken from the stack as
// soon as the stack has it.  The stack is read once a clock: for the parcel
// at P until ir has it, then for the one behind it, which is the second
// parcel of the instruction or the instruction that goes into ir next.  What
// the rules ask of the instruction (its length, what it waits for, its
// channel) and the operand register it names are worked out and read in the
// clock before, for the parcel that goes into ir.  So the issue is decided on
// registers: counters against constants, and no addition (a channel's store
// alone is found by a subtraction).  What else takes arithmetic is settled in
// the clock behind the issue, in which nothing issues that could tell: whether
// a branch by P and d stays in the stack, and whether a store of the
// processor went into it.
//
// Channels 0 to 3 are part of the processor: 0 reads the number of the channel
// that asks for an interrupt, 1 is the Program Fetch Request flag, 2 the exit
// stack, 3 the Local Memory error flag, which never sets.  Channels 4 to 47
// octal are outside; channel 4, the real-time clock, is kept with them.  A
// channel number above 47 names nothing: flags clear, zero read.  A function
// for a channel outside goes out in the clock of its issue, what it reads is
// taken in the clock after, and so is the flag of a test.
//
// Master Clear (rst) clears P, E, the exit stack and the flags of channels 1
// and 2, and sets I.  The processor then does nothing until a channel asks for
// an interrupt: the dead start is the interrupt of the Buffer Memory channel
// that has loaded Local Memory, and it starts the program at the address in
// exit stack location 0, which is 0.  The accumulator, B, the carry and the
// operand registers keep what they held.

module iop_cpu (
	input wire clk,
	input wire rst,  // Master Clear

	// Local Memory: the parcel at o_mem_addr is on i_mem_rdata in the next clock
	output reg  [15:0] o_mem_addr,
	output reg         o_mem_we,
	output wire [15:0] o_mem_wdata,
	input  wire [15:0] i_mem_rdata,
	// a channel has stored in Local Memory, at this address (from registers):
	// nothing issues in this clock if the instruction stack holds the parcel
	input  wire        i_store,
	input  wire [15:0] i_store_addr,

	// channels 4 to 47 octal
	output wire [ 5:0] o_channel,   // of a function or a flag test
	output wire [ 3:0] o_function,
	output wire        o_strobe,    // the function is sent: one clock
	output wire [15:0] o_a,         // the accumulator, valid with the strobe
	input  wire [15:0] i_data,      // what a function 10 to 13 read, in the clock after the strobe
	input  wire        i_busy,      // the flags of channel o_channel
	input  wire        i_done,
	input  wire [ 5:0] i_request,   // the lowest numbered channel that asks for an interrupt, 0 for none

	// for the simulation: nothing issues while i_hold is high; a step (an
	// instruction or an interrupt) issued in the clock before, and what the
	// registers now hold
	input  wire        i_hold,
	output reg         o_step,
	output reg         o_step_interrupt,
	output wire [15:0] o_p,
	output wire [ 8:0] o_b,
	output wire [ 3:0] o_e,
	output wire [ 5:0] o_flags            // held, exit stack boundary, program fetch request, enable delayed, I, C
);

	reg [15:0] a  /* verilator public_flat_rw */;
	reg        c  /* verilator public_flat_rw */;
	reg [ 8:0] b  /* verilator public_flat_rw */;
	reg [15:0] p;  // the instruction that issues next
	reg [ 3:0] e;
	reg        i_en;  // System Interrupt Enable
	reg        i_late;  // 003 has been executed and I is not set yet
	reg        held;  // Master Clear, and no interrupt since
	reg        pfr;  // channel 1: Program Fetch Request flag
	reg [ 8:0] pfr_reg;
	reg        pfr_en;
	reg        bound;  // channel 2: Exit Stack Boundary flag
	reg        pxs_en;

	// The program exit stack.  Master Clear clears it: a location reads zero
	// until it is written.  Location 0, which every interrupt reads, is kept
	// in a register as well.
	(* ramstyle = "MLAB, no_rw_check" *)
	reg  [15:0] xs                                     [ 0:15]  /* verilator public_flat_rw */;
	reg  [15:0] xs_set  /* verilator public_flat_rw */;
	reg  [15:0] xs_0;
	wire [15:0] xs_e = xs_set[e] ? xs[e] : 16'd0;
	(* ramstyle = "no_rw_check" *)
	reg  [15:0] or_mem                                 [0:511]  /* verilator public_flat_rw */;

	assign o_a     = a;
	assign o_p     = p;
	assign o_b     = b;
	assign o_e     = e;
	assign o_flags = {held, bound, pfr, i_late, i_en, c};

	// ---- the instruction that issues next

	reg  [15:0] ir;  // the parcel at P
	reg         there;  // it is, with what was worked out and read for it
	wire [ 6:0] f = ir[15:9];
	wire [ 8:0] d = ir[8:0];

	wire g_shift = (f[6:2] == 5'b00001) || (f[6:2] == 5'b01001);  // 004-007, 044-047
	wire g_imm = (f[6:3] == 4'o01);  // 010-017
	wire g_reg = (f[6:3] == 4'o02) || (f[6:3] == 4'o06);  // 020-027, 060-067
	wire g_mem = (f[6:3] == 4'o03);  // 030-037
	wire g_flag = (f[6:2] == 5'b01000);  // 040-043
	wire g_b = (f[6:3] == 4'o05);  // 050-057
	wire g_branch = (f >= 7'o070) && (f < 7'o140);
	wire g_io = (f >= 7'o140);

	// ---- what the rules ask of an instruction, from its f: worked out as the
	// parcel goes into ir

	function [10:0] classes;
		input [6:0] f;
		reg branch, by_reg, by_mem, no_a;
		reg mode2, mode0;
		reg [1:0] in_k;
		begin
			branch = (f >= 7'o070) && (f < 7'o140);
			mode2  = f[6] ? f[4] : f[2];
			mode0  = f[6] ? f[2] : f[0];
			by_reg = (f[6:3] == 4'o02) || (f[6:3] == 4'o06);
			by_mem = (f[6:3] == 4'o03);
			// in how many clocks it wants the accumulator free, if it uses it
			no_a   = branch;
			in_k   = 2'd1;
			casez (f)
				7'o000, 7'o001, 7'o002, 7'o003: no_a = 1'b1;
				7'o010, 7'o050, 7'o054, 7'o056, 7'o057: in_k = 2'd0;
				7'o015, 7'o016, 7'o017, 7'o022, 7'o023, 7'o025, 7'o062, 7'o063, 7'o065: in_k = 2'd2;
				7'b0011???, 7'b01000??: in_k = 2'd2;  // 030-037, 040-043
				default: ;
			endcase
			classes[0]   = ((f[6:3] == 4'o01) && f[2]) || (branch && mode2 && mode0);  // two parcels
			classes[2:1] = no_a ? 2'd3 : in_k;
			// it wants DP empty: and 024-027, 064-067
			classes[3]   = (f == 7'o011) || (f == 7'o015) || (f == 7'o051) || (by_reg && f[2]);
			classes[4]   = by_reg || by_mem || (branch && mode2);  // it reads an operand register
			// it wants B
			classes[5]   = (f == 7'o011) || (f == 7'o015) || ((f >= 7'o042) && (f < 7'o070)) || (f >= 7'o160);
			classes[6]   = by_mem;
			classes[7]   = branch;
			classes[8]   = branch && !mode2;  // by P and d
			classes[9]   = branch && mode2;  // by an operand register
			classes[10]  = branch && f[6];  // on a condition
		end
	endfunction
	// the channel a parcel names as an instruction (042, 043 and 160 to 177 go
	// by B), and whether it is one outside
	function [6:0] names;
		input f6, f4, f1;
		input [8:0] d;
		input [8:0] by_b;
		reg [8:0] n;
		begin
			n     = (f6 ? f4 : f1) ? by_b : d;
			names = {(n >= 9'd4) && (n < 9'o50), n[5:0]};
		end
	endfunction

	reg  [10:0] cls;  // of the instruction in ir
	reg  [ 5:0] chan;  // its channel; that of a flag test for a clock longer
	reg         sends;  // it is a function for a channel outside
	wire        two = cls[0];
	wire [ 1:0] a_class = cls[2:1];
	wire        c_dp = cls[3];
	wire        c_reg = cls[4];
	wire        c_b = cls[5];
	wire        c_mem = cls[6];
	wire        c_br = cls[7];
	wire        c_rel = cls[8];
	wire        c_abs = cls[9];
	wire        c_cond = cls[10];

	// ---- the operand register the instruction names, read for it in the
	// clock before: for the parcel that is in ir then.  A register that is
	// written in that clock is taken on its way.

	wire [8:0] reg_n = (ir[15:12] == 4'o06) ? b : ir[8:0];  // 060-067 by B; the others, and a branch, by d
	reg [15:0] or_read, or_new;
	reg         or_fresh;
	wire [15:0] or_q = or_fresh ? or_new : or_read;

	// ---- what an instruction waits for (the counters run down to zero)

	reg [3:0] seq;  // clocks until the order of the program lets the next one issue
	reg [3:0] a2;  // until two clocks behind the last delivery to the accumulator
	reg [1:0] dp;  // until the DP register is empty
	reg [8:0] dp_reg;  // the register it has the pointer of
	reg [1:0] b_wait;  // until B is not reserved
	reg [3:0] ma;  // until Local Memory has accepted the last reference
	reg [3:0] adder;  // until the clock an instruction under way has the adder in
	reg       in_last;  // a function that reads issued in the clock before
	reg       late_last;  // an instruction whose word for the accumulator comes now did

	// ---- the instruction stack

	(* ramstyle = "MLAB, no_rw_check" *)
	reg        [15:0] stack                                                             [0:31];
	reg               filling;  // parcels are read for it
	reg        [ 2:0] refill;  // clocks until it is filled again from P; 0: not
	reg        [15:0] load;  // the address of the parcel that is read next
	reg        [ 5:0] count;  // parcels it holds or has asked for, 32 at most
	reg signed [ 6:0] asked;  // parcels asked for from P on,
	reg signed [ 6:0] ahead;  // and those of them that can issue
	reg        [ 2:0] coming;  // a parcel was read one, two, three clocks ago
	// read once a clock: the parcel at P, or the one behind it when ir holds that
	wire       [15:0] next = stack[p[4:0]+{4'b0, there}];
	wire       [15:0] k = next;  // the second parcel of the instruction in ir
	// found in the clock of an issue, acted on in the one behind it:
	reg               went_out;  // the branch by P and d did not stay in the stack
	reg               own_late;  // the instruction stored into a parcel the stack holds
	wire              fills = filling && !went_out && !own_late;

	// ---- the adder and the shifter

	// The word an operand in Local Memory brings is worked on in the clock
	// after the issue, with what the instruction was; nothing that uses the
	// accumulator issues in that clock.
	reg       x_mem;  // the operand of the instruction before is on i_mem_rdata
	reg [2:0] x_op;
	reg       x_flag;  // the flag of the test before is on i_busy or i_done
	reg       x_busy;
	reg       x_in;  // what the function before read is on i_data
	reg store_next, store_now;  // a result is stored in this clock
	reg [15:0] ea;  // address of the operand in memory
	reg [15:0] wd;  // what an instruction stores there

	reg [15:0] x;  // the operand
	always @(*) begin
		if (x_mem) x = i_mem_rdata;
		else if (g_imm) x = f[2] ? k : {7'b0, d};
		else if (g_b) x = {7'b0, b};
		else x = or_q;
	end

	// load, logical product, add, subtract, store, add and store, increment,
	// decrement; 010 to 017 have the first four only
	wire [ 2:0] op_now = g_imm ? {1'b0, f[1:0]} : f[2:0];
	wire [ 2:0] op = x_mem ? x_op : op_now;
	wire [16:0] ca = {c, a};
	wire [16:0] add_a = (op == 3'd6) ? 17'd1 : (op == 3'd7) ? 17'h0FFFF : ca;
	wire [16:0] add_b = (op == 3'd3) ? {1'b0, ~x} : {1'b0, x};
	wire [16:0] sum = add_a + add_b + {16'b0, op == 3'd3};
	reg  [16:0] ca_op;
	always @(*)
		case (op)
			3'd0:    ca_op = {1'b0, x};
			3'd1:    ca_op = {1'b0, a & x};
			3'd4:    ca_op = ca;
			default: ca_op = sum;
		endcase
	wire stores = !g_imm && op_now[2];

	// What goes into an operand register is formed from an operand register,
	// with an adder of its own: Local Memory is slow to deliver, and the
	// adder above has it among its operands.
	wire [15:0] or_a = (op_now == 3'd6) ? 16'd1 : (op_now == 3'd7) ? 16'hFFFF : a;
	wire [15:0] or_sum = or_a + or_q;
	wire [15:0] or_res = (op_now == 3'd4) ? a : or_sum;

	// Carry and accumulator shift as one register of 17 bits; the count is
	// the low 5 bits of d or B, and a circular shift goes by the count modulo
	// 17.  One turn to the right does all four: a turn to the left by n is
	// one to the right by 17 less n, and a shift is a turn with the places
	// cleared that it leaves.  By how much to turn, for each direction and
	// count, is a table of 64 entries of 5 bits.
	function [319:0] turn_table;
		input zero;  // (a function has to have an argument)
		integer i, n, t;
		begin
			turn_table = {320{zero}};
			for (i = 0; i < 64; i = i + 1) begin
				n = i % 32;
				t = (n >= 17) ? (n - 17) : n;
				if ((i >= 32) && (t != 0)) t = 17 - t;  // to the left
				turn_table[i*5+:5] = t[4:0];
			end
		end
	endfunction
	localparam [319:0] TURNS = turn_table(1'b0);
	wire [ 4:0] shift_n = f[5] ? b[4:0] : d[4:0];
	wire        over = (shift_n > 5'd16);
	wire [ 4:0] turn_by = TURNS[{3'b0, f[0], shift_n}*9'd5+:5];
	wire [16:0] turn1 = turn_by[0] ? {ca[0], ca[16:1]} : ca;
	wire [16:0] turn2 = turn_by[1] ? {turn1[1:0], turn1[16:2]} : turn1;
	wire [16:0] turn4 = turn_by[2] ? {turn2[3:0], turn2[16:4]} : turn2;
	wire [16:0] turn8 = turn_by[3] ? {turn4[7:0], turn4[16:8]} : turn4;
	wire [16:0] turn16 = turn_by[4] ? {turn8[15:0], turn8[16]} : turn8;
	wire [16:0] kept = f[1] ? 17'h1FFFF : over ? 17'd0 : f[0] ? (17'h1FFFF << shift_n) : (17'h1FFFF >> shift_n);
	wire [16:0] ca_shift = turn16 & kept;

	// ---- branches

	wire [2:0] mode = f[6] ? f[4:2] : f[2:0];
	reg        met;
	always @(*)
		case (f[1:0])
			2'd0: met = !c;
			2'd1: met = c;
			2'd2: met = (a == 16'd0);
			2'd3: met = (a != 16'd0);
		endcase
	wire        taken = !f[6] || met;
	wire [15:0] p_next = p + (two ? 16'd2 : 16'd1);
	wire        back = mode[0];  // a branch by P and d: backward
	wire [15:0] by_d = p + ({16{back}} ^ {7'b0, d}) + {15'b0, back};
	wire [15:0] target = mode[2] ? (or_q + (mode[0] ? k : 16'd0)) : by_d;
	wire [ 3:0] e_up = e + 4'd1;
	// how P moves when the instruction issues: to the instruction behind it,
	// or not
	wire        exits = (f == 7'o001);
	wire        flows = !exits && !(c_br && taken);
	wire [ 6:0] far = {1'b0, d[5:0]};

	// A branch by P and d stays in the stack if it goes no farther forward
	// than the last parcel that is asked for or will be, and no farther back
	// than the stack will reach then (HR-0808 Part 3 page 3-5).  What will
	// be asked for: the rest of the burst under way, and the bursts that
	// would keep the last parcel 8 ahead of the instruction behind the
	// branch, which are 8, 4 or no parcels.  Those parcels take the places
	// of the oldest ones.  With `asked` parcels asked for from P on and
	// `count` in the stack: forward d < asked + rest + 8, 4 or 0; backward
	// d + asked <= count, and d + asked + rest <= 32 less 8, 4 or 0.  Each
	// is one sum of registers against constants.  The branch issues without
	// it: it is acted on in the clock behind (went_out).
	wire [1:0] rest = 2'd0 - load[1:0];  // of the burst under way
	// asked and rest are 5 at most: 8 parcels more; 9 at most: 4
	reg more8, more4;
	always @(*)
		case (rest)
			2'd0: begin
				more8 = (asked <= 7'sd5);
				more4 = (asked <= 7'sd9);
			end
			2'd1: begin
				more8 = (asked <= 7'sd4);
				more4 = (asked <= 7'sd8);
			end
			2'd2: begin
				more8 = (asked <= 7'sd3);
				more4 = (asked <= 7'sd7);
			end
			2'd3: begin
				more8 = (asked <= 7'sd2);
				more4 = (asked <= 7'sd6);
			end
		endcase
	wire        [8:0] asked_w = {{2{asked[6]}}, asked};
	// backward d + asked + rest; forward d - asked - rest, as d + ~asked + (1 - rest)
	wire        [8:0] rest_w = back ? {7'b0, rest} : (9'd1 - {7'b0, rest});
	wire signed [8:0] reach = {3'b0, d[5:0]} + (back ? asked_w : ~asked_w) + rest_w;
	wire signed [8:0] held_back = {3'b0, count} - asked_w - {3'b0, d[5:0]};
	wire              forward_in = more8 ? (reach < 9'sd8) : more4 ? (reach < 9'sd4) : (reach < 9'sd0);
	wire              reach_in = more8 ? (reach <= 9'sd24) : more4 ? (reach <= 9'sd28) : (reach <= 9'sd32);
	wire              backward_in = (held_back >= 9'sd0) && reach_in;
	wire              in_stack = filling && (d[8:6] == 3'd0) && (back ? backward_in : forward_in);

	// ---- channels

	wire [ 8:0] number = (f[6] ? f[4] : f[1]) ? b : d;  // 042, 043 and 160 to 177 go by B
	wire        ch_own = (number < 9'd4);
	wire [ 6:0] nm0 = names(ir[15], ir[13], ir[10], ir[8:0], b);
	wire        ch_out = nm0[6];
	wire [ 3:0] fn = f[3:0];
	wire        reads = (fn[3:2] == 2'b10);  // functions 10 to 13
	// the channel that asks: 1, 2, or one of the others
	wire [ 5:0] asking = (pfr && pfr_en) ? 6'd1 : (bound && pxs_en) ? 6'd2 : i_request;
	reg  [15:0] own_data;
	always @(*) begin
		own_data = 16'd0;
		if (fn == 4'o10)
			case (number[1:0])
				2'd0: own_data = {10'b0, asking};
				2'd1: own_data = {7'b0, pfr_reg};
				2'd2: own_data = {12'b0, e};
				2'd3: own_data = 16'd0;
			endcase
		else if ((fn == 4'o11) && (number[1:0] == 2'd2)) own_data = xs_e;
		if (!ch_own) own_data = 16'd0;
	end
	// channel 0 is always done; none of the four is ever busy
	wire own_done = (number[1:0] == 2'd0) || ((number[1:0] == 2'd1) && pfr) || ((number[1:0] == 2'd2) && bound);
	wire own_flag = ch_own && !f[0] && own_done;

	// ---- may the instruction issue (R1 to R13 of the spec)

	// the parcels from P on that can issue now: one, two, three of them or
	// more; and in the next clock
	wire ripe1 = !ahead[6] && (ahead[5:0] != 6'd0);
	wire ripe2 = !ahead[6] && (ahead[5:1] != 5'd0);
	wire ripe3 = !ahead[6] && ((ahead[5:2] != 4'd0) || (ahead[1:0] == 2'd3));
	wire soon2 = ripe2 || (ripe1 && coming[2]);
	wire soon3 = ripe3 || (ripe2 && coming[2]);
	wire have = there && (two ? soon2 : ripe1);
	wire have_behind = two ? soon3 : soon2;  // the parcel behind a branch

	// the accumulator is not free in time for it
	reg a_late;
	always @(*)
		case (a_class)
			2'd0: a_late = (a2 > 4'd2);
			2'd1: a_late = (a2 > 4'd3);
			2'd2: a_late = (a2 > 4'd4);
			2'd3: a_late = 1'b0;
		endcase

	wire can = (seq == 4'd0) && !own_late && have && !a_late
		&& !(c_dp && (dp != 2'd0)) && !(c_reg && (dp == 2'd1))
		&& !(c_b && (b_wait != 2'd0))
		&& !(c_mem && (ma > 4'd1))
		&& !(c_br && !have_behind)
		&& !(c_rel && (adder == 4'd2)) && !(c_abs && in_last)
		&& !(c_cond && late_last);

	// A channel's store into a parcel the stack holds, or is about to read:
	// nothing issues in that clock, and the stack is filled again from P.
	wire [15:0] ch_back = load - i_store_addr;
	wire        store_hit = i_store && fills && (ch_back[15:6] == 10'd0) && (ch_back[5:0] <= count);

	// An interrupt is taken in the clock the next instruction would issue in,
	// or in any clock while Master Clear holds the processor.
	wire asks = i_en && ((pfr && pfr_en) || (bound && pxs_en) || (i_request != 6'd0));
	wire point = held || (can && !store_hit);
	wire interrupt = point && !i_hold && asks;
	wire issue = can && !store_hit && !held && !i_hold && !asks;

	// what the instruction is besides
	wire reads_late = (g_reg && (f[2:1] == 2'b01)) || g_mem || c_abs;  // 022, 023, 062, 063
	wire is_input = g_io && reads;

	// a read of an operand register in clock period 2 waits for a store into
	// the same register that is on its way through DP
	wire [1:0] waits = (reads_late && dp[1] && (dp_reg == reg_n)) ? (dp - 2'd1) : 2'd0;
	// and a branch by an operand register for the adder
	wire       adder_waits = c_abs && (adder == 4'd3 + {2'b0, waits});
	wire [1:0] slip = waits + {1'b0, adder_waits};

	// the processor's own store into a parcel the stack holds or is about to
	// read: acted on in the clock behind the issue (own_late)
	wire [15:0] own_back = load - or_q;
	wire        own_hit = filling && (own_back[15:6] == 10'd0) && (own_back[5:0] <= count);

	// the clock period, from the issue, in which the instruction delivers to
	// the accumulator, and the one it has the adder in
	reg [3:0] a_free;
	reg       a_holds;
	reg [3:0] adder_in;
	always @(*) begin
		a_holds  = 1'b1;
		a_free   = 4'd0;
		adder_in = 4'd0;
		casez (f)
			7'o010, 7'o011, 7'o050, 7'o051: a_free = 4'd1;
			7'o014, 7'o015, 7'o020, 7'o021, 7'o054, 7'o060, 7'o061: a_free = 4'd2;
			7'b00001??, 7'b01001??, 7'o012, 7'o013, 7'o052, 7'o053, 7'o055, 7'o056, 7'o057: a_free = 4'd3;
			7'o016, 7'o017, 7'o022, 7'o023, 7'o025, 7'o026, 7'o027, 7'o034, 7'o062, 7'o063, 7'o065, 7'o066, 7'o067:
			a_free = 4'd4;
			7'b01000??: a_free = 4'd5;
			7'o030, 7'o031: a_free = 4'd7;
			7'o032, 7'o033: a_free = 4'd9;
			7'o035, 7'o036, 7'o037: a_free = 4'd11;
			default: begin
				a_holds = is_input;
				a_free  = 4'd6;
			end
		endcase
		casez (f)
			7'o012, 7'o013, 7'o052, 7'o053, 7'o055, 7'o056, 7'o057: adder_in = 4'd2;
			7'o016, 7'o017, 7'o022, 7'o023, 7'o025, 7'o026, 7'o027, 7'o062, 7'o063, 7'o065, 7'o066, 7'o067:
			adder_in = 4'd3;
			7'o032, 7'o033, 7'o035, 7'o036, 7'o037: adder_in = 4'd8;
			default: ;
		endcase
	end

	// How many clocks pass, behind the next one, before the instruction
	// behind this one may issue, and whether the stack is filled again, with
	// the fetch request so many clocks from this one.  (A branch by P and d
	// is taken to stay in the stack, and a store to miss it: went_out and
	// own_late put that right in the next clock.)
	wire [3:0] a2_less = (a2 != 4'd0) ? (a2 - 4'd1) : 4'd0;
	reg  [3:0] after;
	reg  [2:0] request;  // 0: the stack goes on
	always @(*) begin
		request = 3'd0;
		after   = two ? 4'd1 : 4'd0;
		if (exits) begin
			after   = 4'd6;
			request = 3'd2;
		end else if (g_flag) after = 4'd4;
		else if (c_br) begin
			if (taken && c_abs) begin
				// 9 clocks and what it waits, the fetch request 5 before
				after   = {2'b10, slip};
				request = {1'b1, slip};
			end else if (taken) after = 4'd4;
			// a branch on a condition: what follows waits for the criterion
			if (c_cond && (a2_less > after)) after = a2_less;
		end
	end
	// by how much the parcels counted from P on change: by those of the
	// instruction, or by the way of a branch by P and d
	reg [6:0] step;
	always @(*) begin
		if (flows) step = two ? 7'h7E : 7'h7F;
		else if (c_rel) step = back ? far : (7'd0 - far);
		else step = 7'd0;
	end
	wire [6:0] moved = issue ? step : 7'd0;
	wire       moves = issue && flows;  // the instruction behind goes into ir
	// the stack is emptied or left: nothing of it stands in front of the issue
	wire       leaves = interrupt || (issue && !flows);

	// A function for a channel outside goes out in the clock of its issue; the
	// number is there for the flag test in the clock after as well.
	assign o_channel  = chan;
	assign o_function = fn;
	assign o_strobe   = issue && sends;

	// ---- Local Memory

	// A result is stored two clocks after the issue; an operand is read in
	// the clock of the issue; in every other clock the next parcel for the
	// stack is, if the stack wants one.  (The port goes to the operand in
	// every clock the instruction could issue in: if an interrupt or a
	// channel's store takes that clock from it, the stack is filled again
	// anyway, and the address does not wait for either.)
	wire       takes_port = store_now || (can && c_mem);
	wire       read = fills && !takes_port && ((load[1:0] != 2'd0) || (asked <= 7'sd8));
	wire [4:0] stack_at = load[4:0] - 5'd1;  // where the parcel read in the clock before goes
	assign o_mem_wdata = wd;
	always @(*) begin
		o_mem_we = store_now;
		if (store_now) o_mem_addr = ea;
		else if (can && c_mem) o_mem_addr = or_q;
		else o_mem_addr = load;
	end

	// ---- the instruction register in the next clock
	//
	// The stack is read once a clock.  While the parcel at P is not in ir,
	// that one is read, and ir takes it: it then holds the parcel if the stack
	// does (a parcel is in the stack two clocks after it is read, one before it
	// counts as one that can issue).  When it is, the parcel behind it is read.
	// That is the second parcel of an instruction of two, behind which ir is
	// empty for a clock: such an instruction has two clock periods to the next
	// issue in any case.  Behind an instruction of one parcel it is the next
	// instruction, which ir takes as this one issues.
	wire ahead0 = !ahead[6];  // none or more can issue,
	wire ahead_1 = !ahead[6] || (ahead == 7'h7F);  // or one is wanted, not more
	wire fresh1 = coming[1] ^ coming[2];
	wire fresh2 = coming[1] && coming[2];
	wire in1 = fresh2 ? ahead_1 : fresh1 ? ahead0 : ripe1;  // the stack has one parcel from P on,
	wire in2 = fresh2 ? ahead0 : fresh1 ? ripe1 : ripe2;  // two
	wire takes = !there || (moves && !two);

	// what is worked out and read for it: its classes, its channel, its
	// operand register (060-067 by B; the others, and a branch, by d)
	wire [6:0] nm_next = names(next[15], next[13], next[10], next[8:0], b);
	wire       sends_next = (next[15:9] >= 7'o140) && nm_next[6];
	wire [8:0] reg_next = (next[15:12] == 4'o06) ? b : next[8:0];
	wire [8:0] or_raddr = takes ? reg_next : reg_n;
	wire       or_we = issue && stores && g_reg;

	// the exit stack is written by an interrupt, a return jump and function
	// 15 of channel 2
	wire        xs_fn = issue && g_io && ch_own && (number[1:0] == 2'd2) && (fn == 4'o15);
	wire        xs_we = !rst && (interrupt || xs_fn || (issue && g_branch && taken && mode[1]));
	wire [ 3:0] xs_at = xs_fn ? e : e_up;
	wire [15:0] xs_in = interrupt ? p : xs_fn ? a : p_next;

	always @(posedge clk) begin
		or_read  <= or_mem[or_raddr];
		or_fresh <= or_we && (reg_n == reg_next);  // it is of one parcel, and the next goes into ir
		or_new   <= or_res;
		if (takes) begin
			ir  <= next;
			cls <= classes(next[15:9]);
		end
		sends            <= takes ? sends_next : (g_io && ch_out);
		// the number of a flag test stays for the clock its flag is taken in
		chan             <= (takes && !(there && g_flag && ch_out)) ? nm_next[5:0] : nm0[5:0];
		o_step           <= (issue || interrupt) && !rst;
		o_step_interrupt <= interrupt && !rst;

		// the stack takes the parcel that was read in the clock before
		if (coming[0]) stack[stack_at] <= i_mem_rdata;
		if (xs_we) xs[xs_at] <= xs_in;

		if (rst) begin
			p          <= 16'd0;
			e          <= 4'd0;
			i_en       <= 1'b1;
			i_late     <= 1'b0;
			held       <= 1'b1;
			pfr        <= 1'b0;
			pfr_reg    <= 9'd0;
			pfr_en     <= 1'b0;
			bound      <= 1'b0;
			pxs_en     <= 1'b0;
			there      <= 1'b0;
			seq        <= 4'd0;
			a2         <= 4'd0;
			dp         <= 2'd0;
			b_wait     <= 2'd0;
			ma         <= 4'd0;
			adder      <= 4'd0;
			in_last    <= 1'b0;
			late_last  <= 1'b0;
			filling    <= 1'b0;
			refill     <= 3'd0;
			count      <= 6'd0;
			asked      <= 7'sd0;
			ahead      <= 7'sd0;
			coming     <= 3'b000;
			went_out   <= 1'b0;
			own_late   <= 1'b0;
			x_mem      <= 1'b0;
			x_flag     <= 1'b0;
			x_in       <= 1'b0;
			store_next <= 1'b0;
			store_now  <= 1'b0;
			xs_set     <= 16'd0;
			xs_0       <= 16'd0;
		end else begin
			// ---- time passes
			if (seq != 4'd0) seq <= seq - 4'd1;
			a2 <= a2_less;
			if (dp != 2'd0) dp <= dp - 2'd1;
			if (b_wait != 2'd0) b_wait <= b_wait - 2'd1;
			if (ma != 4'd0) ma <= ma - 4'd1;
			if (adder != 4'd0) adder <= adder - 4'd1;
			in_last    <= issue && is_input;
			late_last  <= issue && ((g_mem && (f[2:0] != 3'd4)) || is_input);
			x_mem      <= issue && g_mem;
			x_flag     <= issue && g_flag && ch_out;
			x_in       <= issue && g_io && ch_out && reads;
			store_next <= issue && g_mem && stores;
			store_now  <= store_next;
			went_out   <= issue && c_rel && taken && !in_stack;
			own_late   <= issue && g_mem && stores && own_hit;

			// ---- the stack and what stands in front of the issue
			if (read) begin
				load <= load + 16'd1;
				if (count != 6'd32) count <= count + 6'd1;
			end
			coming <= {coming[1:0], read};
			asked  <= asked + $signed(moved) + $signed({6'b0, read});
			ahead  <= ahead + $signed(moved) + $signed({6'b0, coming[2]});
			if (!there) there <= in1;
			else if (moves) there <= !two && in2;
			if (leaves) there <= 1'b0;
			if (refill != 3'd0) refill <= refill - 3'd1;
			// it is left: nothing is read until it is filled again
			if (interrupt || (issue && (exits || (c_abs && taken)))) begin
				filling <= 1'b0;
				count   <= 6'd0;
				coming  <= 3'b000;
				refill  <= interrupt ? 3'd4 : request;
			end
			// left by the branch by P and d of the clock before, which is
			// then as one by a register: 9 clocks to the next issue, or
			// what its criterion asks, and the fetch request 4 behind it
			if (went_out) begin
				filling <= 1'b0;
				count   <= 6'd0;
				coming  <= 3'b000;
				refill  <= 3'd3;
				seq     <= (seq > 4'd8) ? (seq - 4'd1) : 4'd7;
				there   <= 1'b0;
			end
			// left by the store of the clock before: the fetch request 2
			// behind that instruction, the next issue 7
			if (own_late) begin
				filling <= 1'b0;
				count   <= 6'd0;
				coming  <= 3'b000;
				refill  <= 3'd1;
				seq     <= 4'd5;
				there   <= 1'b0;
			end
			// filled again from P: the fetch request is in this clock
			if ((refill == 3'd1) || store_hit) begin
				filling <= 1'b1;
				load    <= p;
				count   <= 6'd0;
				asked   <= 7'sd0;
				ahead   <= 7'sd0;
				coming  <= 3'b000;
				there   <= 1'b0;
			end
			// the exit stack
			if (xs_we) begin
				xs_set[xs_at] <= 1'b1;
				if (xs_at == 4'd0) xs_0 <= xs_in;
			end

			// ---- an interrupt: I clears, E advances, P is stored there, and
			// the program goes on at the address in location 0
			if (interrupt) begin
				i_en <= 1'b0;
				e    <= e_up;
				if (e_up != 4'd0) p <= xs_0;
				held <= 1'b0;
				seq  <= 4'd8;  // the handler issues 9 clocks behind
			end

			// ---- an instruction issues: everything it does without memory or
			// a channel outside, and what it holds from now on
			if (issue) begin
				p <= p_next;
				if (g_mem) ea <= or_q;
				seq <= after;
				if (a_holds) a2 <= a_free + {2'b0, waits} + 4'd1;
				if (adder_in != 4'd0) adder <= adder_in + {2'b0, waits} - 4'd1;
				if (g_reg && f[2] && (f[1:0] != 2'd0)) begin  // 025-027, 065-067
					dp     <= 2'd3;
					dp_reg <= reg_n;
				end
				if (g_mem) ma <= ((f[2:0] > 3'd4) ? 4'd10 : 4'd3) + {2'b0, waits};
				if (f == 7'o054) b_wait <= 2'd2;
				if ((f == 7'o055) || (f == 7'o056) || (f == 7'o057)) b_wait <= 2'd3;
				x_op   <= f[2:0];
				x_busy <= f[0];

				if (f == 7'o001) begin
					// EXIT: at E = 0 the pointer stays and the boundary flag sets
					p <= xs_e;
					if (e == 4'd0) bound <= 1'b1;
					else e <= e - 4'd1;
				end else if (g_shift) {c, a} <= ca_shift;
				else if (g_imm || g_reg || g_b) begin
					{c, a} <= ca_op;
					if (stores && g_reg) or_mem[reg_n] <= or_res;
					if (stores && g_b) b <= ca_op[8:0];
				end else if (g_branch) begin
					if (taken) begin
						p <= target;
						// a return jump; the boundary flag sets as E reaches 14
						if (mode[1]) begin
							e <= e_up;
							if (e_up == 4'd14) bound <= 1'b1;
						end
						if (mode[2] && (or_q == 16'd0)) begin
							pfr     <= 1'b1;
							pfr_reg <= d;
						end
					end
				end else if (g_flag) begin
					if (!ch_out) c <= own_flag;
				end else if (g_io && !ch_out) begin
					if (ch_own)
						case (number[1:0])
							2'd1:
							case (fn)
								4'o00, 4'o10: pfr <= 1'b0;
								4'o06:        pfr_en <= 1'b0;
								4'o07:        pfr_en <= 1'b1;
								default:      ;
							endcase
							2'd2:
							case (fn)
								4'o00:   bound <= 1'b0;
								4'o06:   pxs_en <= 1'b0;
								4'o07:   pxs_en <= 1'b1;
								4'o14:   e <= a[3:0];
								default: ;  // 15 writes the stack: above
							endcase
							default: ;
						endcase
					if (reads) {c, a} <= {1'b0, own_data};
				end

				// I = 0 also forgets a 003; I = 1 takes effect when the next
				// instruction that is not an EXIT, a 003, a flag test, a
				// branch or a function has been executed
				if (f == 7'o002) begin
					i_en   <= 1'b0;
					i_late <= 1'b0;
				end else if (f == 7'o003) i_late <= 1'b1;
				else if (i_late && !((f == 7'o001) || g_flag || g_branch || g_io)) begin
					i_en   <= 1'b1;
					i_late <= 1'b0;
				end
			end

			// ---- the clock after: the operand from memory, the flag of a
			// channel outside, what a function read there
			if (x_mem) begin
				{c, a} <= ca_op;
				wd     <= ca_op[15:0];
			end
			if (x_flag) c <= x_busy ? i_busy : i_done;
			if (x_in) {c, a} <= {1'b0, i_data};
		end
	end

`ifdef VERILATOR
	// The tests the issue is decided on, as the model has them (iop.rs): on
	// the instruction itself, not on what was worked out for it as it went
	// into ir, and with the sums the model makes.  They must say the same in
	// every clock.
	wire [10:0] now_cls = classes(f);
	wire signed [6:0] ahead_next = ahead + $signed({6'b0, coming[2]});
	wire m_have = (ahead >= 7'sd1) && (!now_cls[0] || (ahead_next >= 7'sd2)) && there;
	wire m_behind = (ahead_next >= (now_cls[0] ? 7'sd3 : 7'sd2));
	wire               m_can = (seq == 4'd0) && !own_late && m_have
		&& !((now_cls[2:1] != 2'd3) && ({1'b0, a2} > {3'b0, now_cls[2:1]} + 5'd2))
		&& !(now_cls[3] && (dp != 2'd0)) && !(now_cls[4] && (dp == 2'd1))
		&& !(now_cls[5] && (b_wait != 2'd0))
		&& !(now_cls[6] && (ma > 4'd1))
		&& !(now_cls[7] && !m_behind)
		&& !(now_cls[8] && (adder == 4'd2)) && !(now_cls[9] && in_last)
		&& !(now_cls[10] && late_last);
	wire signed [6:0] m_past = asked - 7'sd1 + $signed({5'b0, rest});
	wire [3:0] m_to_come = {2'b0, rest} + ((m_past <= 7'sd4) ? 4'd8 : (m_past <= 7'sd8) ? 4'd4 : 4'd0);
	wire [5:0] m_reach = (count > 6'd32 - {2'b0, m_to_come}) ? (6'd32 - {2'b0, m_to_come}) : count;
	wire signed [6:0] m_back = $signed({1'b0, m_reach}) - asked;
	wire signed [6:0] m_fore = asked + $signed({3'b0, m_to_come});
	wire m_in_stack = filling && (d[8:6] == 3'd0) && (back ? ($signed(far) <= m_back) : ($signed(far) < m_fore));
	always @(posedge clk)
		if (!rst) begin
			if (can !== m_can) begin
				$display("iop_cpu: the issue is decided on what is not of the instruction (P %04x)", p);
				$finish;
			end
		end
	// the instruction that issues is the parcel at P, with what was worked
	// out and read for it, and nothing that uses the accumulator issues in
	// the clock a word for it arrives
	always @(posedge clk)
		if (!rst && issue) begin
			if ((ir !== stack[p[4:0]]) || (two && (k !== stack[p[4:0]+5'd1]))) begin
				$display("iop_cpu: an instruction issues that is not the one at P (P %04x)", p);
				$finish;
			end
			if ((cls !== now_cls) || (sends !== (g_io && ch_out)) || ((g_io || g_flag) && (chan !== number[5:0]))) begin
				$display("iop_cpu: an instruction issues as another one (P %04x)", p);
				$finish;
			end
			if ((late_last || x_flag) && ((a_class != 2'd3) || c_cond)) begin
				$display("iop_cpu: an instruction issues on an accumulator that is not there yet (P %04x)", p);
				$finish;
			end
			if ((c_reg || g_reg) && (or_q !== or_mem[reg_n])) begin
				$display("iop_cpu: an instruction issues with an operand register that is not read (P %04x)", p);
				$finish;
			end
			if (c_rel && taken && (in_stack !== m_in_stack)) begin
				$display("iop_cpu: a branch stays in the stack, or leaves it, wrongly (P %04x)", p);
				$finish;
			end
			if (a_holds && ({1'b0, a_free} + {3'b0, waits} + 5'd1 > 5'd15)) begin
				$display("iop_cpu: the accumulator is held longer than is counted (P %04x)", p);
				$finish;
			end
		end
`endif

endmodule
