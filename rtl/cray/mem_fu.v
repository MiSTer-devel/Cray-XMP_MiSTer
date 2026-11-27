//******************************************
//       Memory Functional Unit
//******************************************
//
// Sequences every memory reference an instruction makes:
//
//   10h-13h   one word between memory and an A or S register, address (Ah) + jkm
//   034-037   (Ai) words between memory and the B or T registers, starting at
//             address (A0) and register jk, registers wrapping from 77 to 00
//   176, 177  VL words between memory and a V register, starting at address
//             (A0) and stepping by (Ak); or, for the gather 176i1k and the
//             scatter 1771jk, at the addresses (A0) + (Vk element)
//
// Every one of them issues without waiting for memory, and the instructions
// behind it go on (CSM-0111000 pages 2-6, 5-40, 5-64, 5-92).
//
// The block and vector transfers go through the X-MP's three memory ports
// (HR-0097B pages 29 to 31, 148, 200 and 201), each a transfer sequencer of
// its own (mem_xfer.v) with a port of its own to the memory multiplexer:
//
//   Port A   034, and 176 when port B is busy
//   Port B   036 and 176
//   Port C   035, 037, 177 and the scalar references
//
// A read transfer and a write transfer run at the same time only in the
// bidirectional memory mode (the BDM bit of the exchange package, 0026 and
// 0025): with it clear, 176, 034 and 036 hold while port C is busy, and
// 177, 035 and 037 while port A or B is.  A transfer issues in the clock
// its port starts it, and goes on in the background.
//
// A scalar reference issues as soon as both its parcels are there, and
// while no port is busy ("Port A, B, or C busy").  Its address is formed
// and checked against the field in the clock after, and it then waits in a
// queue, or goes past it when nothing is in front: scalar references are
// made in the order they issued, one presented to memory as soon as the one
// before has been taken.  The register of a
// load is reserved until its word has come, which the unit tells the A or
// the S registers a clock ahead (o_sc_a, o_sc_s).  The word of a store is
// taken from its register when the instruction issues.  No block or vector
// transfer starts while a scalar reference is waiting.
//
// All addresses are relative to the data base address and are checked against
// the limit address (manual 3-43).  A reference outside the field is not
// made: a store is dropped, a load delivers zero, and o_range_err pulses so
// the operand range flag can be set.

module mem_fu (
	clk,
	rst,
	i_cip,
	i_lip,
	i_scalar,
	i_block,
	i_vector_length,
	i_vstart_ld,
	i_vstart_st,
	i_bdm,
	i_data_base_addr,
	i_data_limit_addr,
	//interface to A rf
	i_a0_data,
	i_a0_srcs,
	i_a0_sel,
	i_ai_data,
	i_ak_data,
	i_ah_data,
	o_sc_a,
	//interface to S rf
	i_si_data,
	o_sc_s,
	o_sc_num,
	o_sc_data,
	//interface to V regs
	i_v0_data,
	i_v1_data,
	i_v2_data,
	i_v3_data,
	i_v4_data,
	i_v5_data,
	i_v6_data,
	i_v7_data,
	o_xv_wr,
	o_xv_last,
	o_xv_wr_idx,
	o_xv_rd_idx,
	o_xv_data,
	i_xv_avail,
	i_xvk_avail,
	o_xv_num,
	o_xvk_num,
	o_xv_reads,
	//interface to B rf
	o_b_rd_addr,
	i_b_rd_data,
	o_b_wr_addr,
	o_b_wr_en,
	o_b_wr_data,
	//interface to T rf
	o_t_rd_addr,
	i_t_rd_data,
	o_t_wr_addr,
	o_t_wr_en,
	o_t_wr_data,
	//the scalar references' memory port
	o_mem_addr,
	o_mem_len,
	o_mem_wr_data,
	o_mem_wr_en,
	o_mem_ce,
	i_mem_take,
	i_mem_ack,
	//the three ports' memory ports
	o_xm_ce,
	o_xm_we,
	o_xm_addr,
	o_xm_len,
	o_xm_wdata,
	i_xm_take,
	i_xm_ack,
	i_mem_rd_data,
	//instruction issue
	o_sc_ready,
	o_blk_ready,
	o_ld_ready,
	o_st_ready,
	o_mem_issue,
	i_issue,
	o_blk_b_rd,
	o_blk_b_wr,
	o_blk_t_rd,
	o_blk_t_wr,
	o_unsure,
	o_sc_pending,
	o_mem_busy,
	o_range_err
);

	parameter V_READ_WAIT = 2;  // clocks from asking a V register for an element to its data

	//system signals
	input wire clk;
	input wire rst;
	input wire [15:0] i_cip;  //current instruction parcel
	input wire [15:0] i_lip;  //lower instruction parcel
	input wire i_scalar;  //the current instruction is a scalar reference
	input wire i_block;  //it is a block transfer
	input wire [6:0] i_vector_length;
	input wire i_vstart_ld;  //the vector scheduler starts a 176
	input wire i_vstart_st;  //a 177
	input wire i_bdm;  //bidirectional memory mode
	// The data field follows CSM-0111000 pages 3-19 to 3-21: only the low 22 bits of
	// an address count, memory has four million words, and a load from outside the
	// field delivers zero.
	input wire [23:0] i_data_base_addr;
	input wire [23:0] i_data_limit_addr;
	//interface to registers
	input wire [23:0] i_a0_data;
	//where (A0) is read from: its register (the top one) or a lane of results,
	//with one bit for the one that it is
	input wire [143:0] i_a0_srcs;
	input wire [5:0] i_a0_sel;
	input wire [23:0] i_ai_data;
	input wire [23:0] i_ak_data;
	input wire [21:0] i_ah_data;
	input wire [63:0] i_si_data;
	//a scalar load: its word is in o_sc_data, for A or S register o_sc_num
	output reg o_sc_a;
	output reg o_sc_s;
	output reg [2:0] o_sc_num;
	output reg [63:0] o_sc_data;
	input wire [63:0] i_v0_data;
	input wire [63:0] i_v1_data;
	input wire [63:0] i_v2_data;
	input wire [63:0] i_v3_data;
	input wire [63:0] i_v4_data;
	input wire [63:0] i_v5_data;
	input wire [63:0] i_v6_data;
	input wire [63:0] i_v7_data;
	//the three ports, A, B and C from bit 0 up: what each hands to or asks of
	//the V registers
	output wire [2:0] o_xv_wr;  //176: o_xv_data holds element o_xv_wr_idx
	output wire [2:0] o_xv_last;  //176: the last element is delivered with this clock
	output wire [17:0] o_xv_wr_idx;
	output wire [17:0] o_xv_rd_idx;  //177: the element about to be read; 176i1k, 1771jk: the element of Vk with the next address
	output wire [191:0] o_xv_data;
	input wire [2:0] i_xv_avail;  //and it is in its register
	input wire [2:0] i_xvk_avail;  //176i1k, 1771jk: so is the element of Vk with its address
	output wire [8:0] o_xv_num;  //the V register of the vector transfer under way
	output wire [8:0] o_xvk_num;  //the V register with the addresses of a gather or scatter
	output wire [23:0] o_xv_reads;  //the V registers a vector transfer reads, one bit a register
	//only port C reads the B and T registers and only ports A and B write them
	output wire [5:0] o_b_rd_addr;
	input wire [23:0] i_b_rd_data;
	output wire [5:0] o_b_wr_addr;
	output wire o_b_wr_en;
	output wire [23:0] o_b_wr_data;
	output wire [5:0] o_t_rd_addr;
	input wire [63:0] i_t_rd_data;
	output wire [5:0] o_t_wr_addr;
	output wire o_t_wr_en;
	output wire [63:0] o_t_wr_data;
	//interface to memory
	output wire [21:0] o_mem_addr;
	output wire [6:0] o_mem_len;
	output wire [63:0] o_mem_wr_data;
	output wire o_mem_wr_en;
	output wire o_mem_ce;
	input wire i_mem_take;  //the request presented is taken this clock
	input wire i_mem_ack;  //a word read for a scalar reference is in i_mem_rd_data
	output wire [2:0] o_xm_ce;
	output wire [2:0] o_xm_we;
	output wire [65:0] o_xm_addr;
	output wire [20:0] o_xm_len;
	output wire [191:0] o_xm_wdata;
	input wire [2:0] i_xm_take;
	input wire [2:0] i_xm_ack;
	input wire [63:0] i_mem_rd_data;
	//instruction issue
	output wire o_sc_ready;  //a scalar reference may issue
	output wire o_blk_ready;  //the block transfer in i_cip may
	output wire o_ld_ready;  //a 176 may
	output wire o_st_ready;  //a 177 may
	output wire o_mem_issue;  //a vector transfer has started and its instruction has not issued
	input wire i_issue;  //the current instruction issues this clock
	output wire o_blk_b_rd;  //a block transfer is reading the B registers
	output wire o_blk_b_wr;  //writing them
	output wire o_blk_t_rd;  //the same for the T registers
	output wire o_blk_t_wr;
	output wire o_unsure;  //a transfer is under way that may leave the field: what is behind it waits
	output wire o_sc_pending;  //a scalar reference has issued and is not done
	output wire o_mem_busy;  //anything is under way
	output wire o_range_err;  //a reference outside the field was dropped

	wire [15:0] ins = i_cip;
	wire [ 6:0] op = ins[15:9];
	wire [21:0] jkm = {ins[5:0], i_lip[15:0]};  //the displacement of a scalar reference

	//-----------------------------------------------------------------
	// The field
	//-----------------------------------------------------------------
	// absolute address = address + base, valid below the limit and below the top
	// of memory, four million words.  The low 22 bits of the address count; the
	// base has 24.  Whether an address is inside is told without the sum: it is
	// if it is below the words the field has from its base on (room).
	reg [23:0] base;
	reg [22:0] limit;
	reg [22:0] room;  // words of the field from its base on
	always @(posedge clk) begin
		base  <= i_data_base_addr;
		limit <= (|i_data_limit_addr[23:22]) ? 23'h400000 : {1'b0, i_data_limit_addr[21:0]};
		room  <= ({1'b0, base} < {2'b0, limit}) ? (limit - base[22:0]) : 23'd0;
	end

	// For the transfers' quick look at their first address and step: whether the
	// field has 64, 1,024 and 65,536 words, and the highest first address for each.
	reg [22:0] top1, top2, top3;
	reg ok1, ok2, ok3;
	always @(posedge clk) begin
		ok1  <= (room >= 23'd64);
		ok2  <= (room >= 23'd1024);
		ok3  <= (room >= 23'd65536);
		top1 <= room - 23'd64;
		top2 <= room - 23'd1024;
		top3 <= room - 23'd65536;
	end

	// The look itself, (A0) against the three highest first addresses, is the
	// long part: (A0) comes out of the A registers late, read from its register
	// or off a lane of results, whichever the register file has picked.  So
	// the three tests are made on the register and on every lane at once, and
	// the register file's pick chooses among the answers.
	reg     [2:0] fit;  // (A0) is no higher than top1, top2, top3, and the field has the words
	integer       src;
	always @* begin
		fit = 3'b000;
		for (src = 0; src < 6; src = src + 1) begin
			fit[0] = fit[0] | (i_a0_sel[src] && ok1 && (i_a0_srcs[24*src+22+:2] == 2'd0) && ({1'b0, i_a0_srcs[24*src+:22]} <= top1));
			fit[1] = fit[1] | (i_a0_sel[src] && ok2 && (i_a0_srcs[24*src+22+:2] == 2'd0) && ({1'b0, i_a0_srcs[24*src+:22]} <= top2));
			fit[2] = fit[2] | (i_a0_sel[src] && ok3 && (i_a0_srcs[24*src+22+:2] == 2'd0) && ({1'b0, i_a0_srcs[24*src+:22]} <= top3));
		end
	end

	//-----------------------------------------------------------------
	// The three ports
	//-----------------------------------------------------------------
	wire [2:0] x_busy, x_issue, x_unsure, x_range_err;
	wire [2:0] x_blk_b_rd, x_blk_b_wr, x_blk_t_rd, x_blk_t_wr;
	wire [2:0] x_b_wr_en, x_t_wr_en;
	wire [5:0] x_b_rd_addr        [0:2];
	wire [5:0] x_b_wr_addr        [0:2];
	wire [5:0] x_t_rd_addr        [0:2];
	wire [5:0] x_t_wr_addr        [0:2];
	wire       busy_a = x_busy[0];
	wire       busy_b = x_busy[1];
	wire       busy_c = x_busy[2];

	// which port the instruction in i_cip takes, and whether it is free
	wire blk_wr = ins[9];  // 035, 037
	wire to_a = (op == 7'o034);
	wire to_b = (op == 7'o036);
	// (no transfer starts while a scalar reference is waiting or on its way:
	// the references of a program reach memory in the order they issued)
	wire ld_can = (!busy_b || !busy_a) && (i_bdm || !busy_c) && !o_sc_pending;
	wire st_can = !busy_c && (i_bdm || (!busy_a && !busy_b)) && !o_sc_pending;
	assign o_ld_ready = ld_can;
	assign o_st_ready = st_can;
	// A block transfer also holds while the one that goes the other way between
	// the same registers is in process: 034 for a 035 and 036 for a 037, and
	// the other way round (HR-0097B page 148).
	wire blk_other = to_a ? x_blk_b_rd[2] : to_b ? x_blk_t_rd[2] : (ins[10] ? x_blk_t_wr[1] : x_blk_b_wr[0]);
	assign o_blk_ready = !o_sc_pending && !blk_other && (to_a ? (!busy_a && (i_bdm || !busy_c)) : to_b ? (!busy_b && (i_bdm || !busy_c)) : (!busy_c && (i_bdm || (!busy_a && !busy_b))));

	wire blk_go = i_block && i_issue;
	wire [2:0] x_start = {
		blk_go && blk_wr || i_vstart_st,  // port C
		blk_go && to_b || (i_vstart_ld && !busy_b),  // port B
		blk_go && to_a || (i_vstart_ld && busy_b)  // port A
	};

	genvar x;
	generate
		for (x = 0; x < 3; x = x + 1) begin : g_port
			mem_xfer #(
				.V_READ_WAIT(V_READ_WAIT),
				.LOADS      (x != 2),
				.STORES     (x == 2)
			) port (
				.clk            (clk),
				.rst            (rst),
				.i_cip          (i_cip),
				.i_vector_length(i_vector_length[5:0]),
				.i_start        (x_start[x]),
				.i_issue        (i_issue),
				.i_base         (base[21:0]),
				.i_room         (room),
				.i_fit          (fit),
				.i_a0_data      (i_a0_data),
				.i_ai_count     (i_ai_data[6:0]),
				.i_ak_data      (i_ak_data),
				.i_v0_data      (i_v0_data),
				.i_v1_data      (i_v1_data),
				.i_v2_data      (i_v2_data),
				.i_v3_data      (i_v3_data),
				.i_v4_data      (i_v4_data),
				.i_v5_data      (i_v5_data),
				.i_v6_data      (i_v6_data),
				.i_v7_data      (i_v7_data),
				.o_v_wr         (o_xv_wr[x]),
				.o_v_last       (o_xv_last[x]),
				.o_v_wr_idx     (o_xv_wr_idx[6*x+:6]),
				.o_v_rd_idx     (o_xv_rd_idx[6*x+:6]),
				.o_v_data       (o_xv_data[64*x+:64]),
				.i_v_avail      (i_xv_avail[x]),
				.i_vk_avail     (i_xvk_avail[x]),
				.o_b_rd_addr    (x_b_rd_addr[x]),
				.i_b_rd_data    (i_b_rd_data),
				.o_b_wr_addr    (x_b_wr_addr[x]),
				.o_b_wr_en      (x_b_wr_en[x]),
				.o_t_rd_addr    (x_t_rd_addr[x]),
				.i_t_rd_data    (i_t_rd_data),
				.o_t_wr_addr    (x_t_wr_addr[x]),
				.o_t_wr_en      (x_t_wr_en[x]),
				.o_mem_addr     (o_xm_addr[22*x+:22]),
				.o_mem_len      (o_xm_len[7*x+:7]),
				.i_mem_rd_data  (i_mem_rd_data),
				.o_mem_wr_data  (o_xm_wdata[64*x+:64]),
				.o_mem_wr_en    (o_xm_we[x]),
				.o_mem_ce       (o_xm_ce[x]),
				.i_mem_take     (i_xm_take[x]),
				.i_mem_ack      (i_xm_ack[x]),
				.o_busy         (x_busy[x]),
				.o_mem_issue    (x_issue[x]),
				.o_v_num        (o_xv_num[3*x+:3]),
				.o_vk_num       (o_xvk_num[3*x+:3]),
				.o_v_reads      (o_xv_reads[8*x+:8]),
				.o_blk_b_rd     (x_blk_b_rd[x]),
				.o_blk_b_wr     (x_blk_b_wr[x]),
				.o_blk_t_rd     (x_blk_t_rd[x]),
				.o_blk_t_wr     (x_blk_t_wr[x]),
				.o_unsure       (x_unsure[x]),
				.o_range_err    (x_range_err[x])
			);
		end
	endgenerate

	// port A writes the B registers, port B the T registers, port C reads both
	assign o_b_rd_addr = x_b_rd_addr[2];
	assign o_t_rd_addr = x_t_rd_addr[2];
	assign o_b_wr_addr = x_b_wr_addr[0];
	assign o_b_wr_en   = x_b_wr_en[0];
	assign o_b_wr_data = o_xv_data[23:0];
	assign o_t_wr_addr = x_t_wr_addr[1];
	assign o_t_wr_en   = x_t_wr_en[1];
	assign o_t_wr_data = o_xv_data[127:64];
	assign o_blk_b_rd  = x_blk_b_rd[2];
	assign o_blk_b_wr  = x_blk_b_wr[0];
	assign o_blk_t_rd  = x_blk_t_rd[2];
	assign o_blk_t_wr  = x_blk_t_wr[1];
	assign o_mem_issue = |x_issue;
	assign o_unsure    = |x_unsure;

	//-----------------------------------------------------------------
	// Scalar references
	//-----------------------------------------------------------------
	// What the current instruction would refer to is taken in every clock, and is
	// a reference if the instruction is one and issues.  In the clock after, the
	// address is formed, of which the low 22 bits count, and looked at: it is
	// inside the field if it is below the words the field has from its base on
	// (room).  So the operand range flag is set before the next instruction can
	// issue, which is the clock after that at the earliest: a scalar reference
	// has two parcels.  The reference then joins the queue.
	reg e_v;
	reg e_store, e_s;
	reg [2:0] e_i;
	reg [21:0] e_ah, e_jkm;
	reg  [63:0] e_sdata;  // the registers as they come: which of them is stored is picked a clock later
	reg  [23:0] e_adata;
	wire [21:0] e_rel = e_ah + e_jkm;
	wire        e_oof = ({1'b0, e_rel} >= room);
	always @(posedge clk) begin
		e_v     <= !rst && i_scalar && i_issue;
		e_store <= ins[12];
		e_s     <= ins[13];
		e_i     <= ins[8:6];
		e_ah    <= i_ah_data;
		e_jkm   <= jkm;
		e_sdata <= i_si_data;
		e_adata <= i_ai_data;
	end

	// The queue, and the reference at its front, which is presented to memory
	// until it is taken.  A load from outside the field delivers zero and a
	// store there is dropped, neither with a request to memory.  The loads
	// taken and not yet answered are remembered in order (so), to give each
	// word to its register; a zero is given when nothing is on its way, and
	// nothing is taken while it waits, so that a word can never come for a
	// load behind it.
	localparam QW = 6 + 22 + 64;
	(* ramstyle = "MLAB, no_rw_check" *) reg [QW-1:0] q[0:7];
	reg [2:0] q_wr, q_rd;
	reg  [   3:0] q_n;
	reg           q_ok;  // there is room for a reference that issues now
	wire [QW-1:0] head = q[q_rd];

	reg        fr_valid;
	reg        fr_oof;
	reg        fr_store;
	reg        fr_s;
	reg [ 2:0] fr_i;
	reg [21:0] fr_addr;
	reg [63:0] fr_word;

	localparam SO = 8;
	reg [4:0] so[0:SO-1];  // {zero, s, i}
	reg [$clog2(SO)-1:0] so_wr, so_rd;
	reg  [$clog2(SO):0] so_n;
	wire                so_room = (so_n != SO[$clog2(SO):0]);
	wire                so_zero = (so_n != 0) && so[so_rd][4];
	wire                sc_ack = i_mem_ack && (so_n != 0) && !so_zero;

	wire       fr_mem = fr_valid && !fr_oof;
	wire       fr_drop = fr_valid && fr_oof && fr_store;
	wire       fr_zero = fr_valid && fr_oof && !fr_store;
	wire       sc_req = fr_mem && (fr_store || so_room) && !so_zero;
	wire       fr_done = fr_drop || (fr_zero && (so_n == 0)) || (sc_req && i_mem_take);
	// (a reference with nothing in front of it goes to the front at once,
	// past the queue)
	wire       fr_free = !fr_valid || fr_done;
	wire       fr_load = (q_n != 4'd0) && fr_free;
	wire       fr_past = e_v && (q_n == 4'd0) && fr_free;
	wire       so_push = (fr_zero && (so_n == 0)) || (sc_req && i_mem_take && !fr_store);
	wire       so_pop = so_zero || sc_ack;
	wire [3:0] q_n_nxt = q_n + {3'd0, e_v && !fr_past} - {3'd0, fr_load};

	always @(posedge clk) begin
		o_sc_a <= 1'b0;
		o_sc_s <= 1'b0;
		if (rst) begin
			q_wr     <= 3'd0;
			q_rd     <= 3'd0;
			q_n      <= 4'd0;
			q_ok     <= 1'b1;
			fr_valid <= 1'b0;
			so_wr    <= 3'd0;
			so_rd    <= 3'd0;
			so_n     <= 4'd0;
		end else begin
			if (e_v && !fr_past) begin
				q[q_wr] <= {e_oof, e_store, e_s, e_i, e_rel, e_s ? e_sdata : {40'b0, e_adata}};
				q_wr    <= q_wr + 3'd1;
			end
			q_n  <= q_n_nxt;
			q_ok <= (q_n_nxt < 4'd7);

			if (fr_load) begin
				q_rd     <= q_rd + 3'd1;
				fr_valid <= 1'b1;
				fr_oof   <= head[91];
				fr_store <= head[90];
				fr_s     <= head[89];
				fr_i     <= head[88:86];
				fr_addr  <= head[85:64] + base[21:0];
				fr_word  <= head[63:0];
			end else if (fr_past) begin
				fr_valid <= 1'b1;
				fr_oof   <= e_oof;
				fr_store <= e_store;
				fr_s     <= e_s;
				fr_i     <= e_i;
				fr_addr  <= e_rel + base[21:0];
				fr_word  <= e_s ? e_sdata : {40'b0, e_adata};
			end else if (fr_done) fr_valid <= 1'b0;

			if (so_push) begin
				so[so_wr] <= {fr_zero, fr_s, fr_i};
				so_wr     <= so_wr + 1'd1;
			end
			if (so_pop) so_rd <= so_rd + 1'd1;
			so_n <= so_n + {{$clog2(SO) {1'b0}}, so_push} - {{$clog2(SO) {1'b0}}, so_pop};

			//the word of a load is in o_sc_data in the next clock
			if (so_pop) begin
				o_sc_a   <= !so[so_rd][3];
				o_sc_s   <= so[so_rd][3];
				o_sc_num <= so[so_rd][2:0];
			end
		end
	end

	always @(posedge clk)
		if (sc_ack) o_sc_data <= i_mem_rd_data;
		else if (so_zero) o_sc_data <= 64'b0;

	assign o_sc_pending = e_v || (q_n != 4'd0) || fr_valid || (so_n != 0);
	assign o_sc_ready   = !busy_a && !busy_b && !busy_c && q_ok;
	assign o_range_err  = (|x_range_err) || (e_v && e_oof);
	assign o_mem_busy   = busy_a || busy_b || busy_c || o_sc_pending;

	assign o_mem_addr    = fr_addr;
	assign o_mem_len     = 7'd1;
	assign o_mem_wr_data = fr_word;
	assign o_mem_ce      = sc_req;
	assign o_mem_wr_en   = sc_req && fr_store;

`ifdef VERILATOR
	// a transfer and a scalar reference are never under way at the same time,
	// and the queue never runs over
	always @(posedge clk)
		if (!rst && (((busy_a || busy_b || busy_c) && o_sc_pending) || (e_v && q_n[3]))) begin
			$display("mem_fu: a scalar reference beside a transfer, or the queue over its end");
			$finish;
		end
`endif

endmodule
