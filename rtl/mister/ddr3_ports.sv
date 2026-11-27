// The DE10-Nano's HPS DDR3 shared by several users, through the MiSTer DDRAM
// port.
//
// A user's address counts 64-bit words from physical 0x3000_0000, where Linux
// sees the same memory through /dev/mem and where the MiSTer menu loads files
// whose CONF_STR entry gives an address.  Bytes are reversed so a file of
// big-endian 64-bit words lands with its first byte in rdata[63:56].
//
// Port contract, for each user:
//   - a request is req with we, addr, len and wdata.  It is taken in a clock
//     where take is high (for user 0: where it is made and free0 is high),
//     and is then carried out in its turn: requests go to the DDR3 in the
//     order they were taken, and the words of reads come back in that order.
//   - a read is of len words from addr, 1 to 64, which the bridge delivers
//     one a clock; a write is of one word.
//   - ack is a registered one-clock pulse per read word.  rdata, which all
//     users share, is valid only during ack.
//   - a user that streams (STREAM[n] = 1) presents its next request in the
//     clock after take, and hears nothing more of a write once it is taken.
//   - any other user holds req, we, addr, len and wdata until the ack of a
//     write, which comes the clock after take, or the last ack of a read;
//     its request is looked at again from the clock after that ack.
//   - while user_rst[n] is high the user's requests are not taken, and the
//     words of its reads still to come are dropped: the CPU can be reset
//     while this port runs on.
//
// The users take turns: the one served last is the last to be looked at
// again.  Nothing is taken while 32 reads are still to be answered, the
// places the list of them has.  A request goes to the bridge in the clock it
// is taken when nothing is in its way, and a word read is handed on as the
// bridge gives it.
//
// Lines kept (LINES).  A read of a whole 16-word line of central memory that
// its user marks as code, as the CPU's instruction buffers do, leaves the
// line here as its words go by, LINES lines at most, each in the place the
// low bits of its number name.  The next read of that line is answered from
// here, a word a clock, in its turn among the reads as any other, and does
// not go to the DDR3.  A write to a line that is kept puts it out, and one to
// a line that is on its way in keeps it from being kept, so what is here is
// always what the DDR3 holds.  Reads of lines and writes into central memory
// pass a stage where the line's place is looked up; everything behind them
// follows through it, in order.
module ddr3_ports #(
	parameter         N      = 2,
	parameter [N-1:0] STREAM = {N{1'b0}},
	parameter         LINES  = 1024        // lines kept, a power of two; 0: none
) (
	input wire clk,
	input wire reset,

	input  wire [   N-1:0] req,
	input  wire [   N-1:0] we,
	input  wire [   N-1:0] code,      // a read of instructions: a whole line of it may be kept
	input  wire [ 7*N-1:0] len,
	input  wire [25*N-1:0] addr,
	input  wire [64*N-1:0] wdata,
	input  wire [   N-1:0] user_rst,
	output wire [   N-1:0] take,
	output wire            free0,     // user 0's request is taken this clock if it is made
	output reg  [   N-1:0] ack,
	output reg  [    63:0] rdata,     // (one of two registers)

	output wire        DDRAM_CLK,
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

	localparam W    = (N > 1) ? $clog2(N) : 1;
	localparam CF   = 8;                        // requests taken and not yet presented, at most
	localparam CA   = $clog2(CF);
	localparam RF   = 32;                       // reads whose words are still to come, at most
	localparam RA   = $clog2(RF);
	localparam KEPT = (LINES != 0);
	localparam ICL  = KEPT ? LINES : 2;
	localparam ICA  = $clog2(ICL);              // a line of central memory has 18 bits of number:
	localparam ICT  = 18 - ICA;                 // its place here, and its tag

	function [63:0] bswap;
		input [63:0] d;
		bswap = {d[7:0], d[15:8], d[23:16], d[31:24], d[39:32], d[47:40], d[55:48], d[63:56]};
	endfunction

	assign DDRAM_CLK = clk;
	assign DDRAM_BE  = 8'hFF;

	//-----------------------------------------------------------------
	// Which request is taken
	//-----------------------------------------------------------------
	// The user to serve is the first after the one served last that asks and
	// may be served.  What depends on the requests is one bit a user, and the
	// address and the data are gathered with those bits: nothing is indexed
	// with a number that has to be worked out from the requests first.
	// User 0 asks late in the clock (the CPU, whose request comes out of its
	// own multiplexer): what the others would give is gathered without it, and
	// user 0's own comes in by one pick at the end.  When user 0 is not first
	// the first among the others is first of all.
	reg  [N-1:0] mask;  // a user that holds its request until its acknowledge, and has been taken
	reg  [W-1:0] last;  // the user served last
	wire         rf_room;
	wire [N-1:0] ready = req & ~mask & ~user_rst & {N{rf_room}};
	reg  [N-1:0] first;
	reg  [N-1:0] first_o;  // first among users 1 to N-1
	reg [W-1:0] pick, pick_o;
	reg [6:0] pick_len, len_o;
	reg [24:0] pick_addr, addr_o;
	reg [63:0] pick_wdata, wdata_o;
	reg sooner, sooner_o;
	wire pick_we = |(first & we);
	wire pick_code = |(first & code);
	integer k, n;
	// how many places after the one served last a user comes, going round
	function automatic [W:0] place(input integer user, input [W-1:0] of);
		integer d;
		begin
			d     = user - 1 - {{(32 - W) {1'b0}}, of};
			place = (d < 0) ? d[W:0] + N[W:0] : d[W:0];
		end
	endfunction
	always @(*) begin
		pick_o  = last;
		len_o   = 7'd0;
		addr_o  = 25'd0;
		wdata_o = 64'd0;
		for (n = 0; n < N; n = n + 1) begin
			sooner   = 1'b0;
			sooner_o = 1'b0;
			for (k = 0; k < N; k = k + 1)
			if ((k != n) && (place(k, last) < place(n, last))) begin
				sooner = sooner | ready[k];
				if (k != 0) sooner_o = sooner_o | ready[k];
			end
			first[n]   = ready[n] && !sooner;
			first_o[n] = (n != 0) && ready[n] && !sooner_o;
			if (first_o[n]) pick_o = n[W-1:0];
			len_o   = len_o | ({7{first_o[n]}} & len[7*n+:7]);
			addr_o  = addr_o | ({25{first_o[n]}} & addr[25*n+:25]);
			wdata_o = wdata_o | ({64{first_o[n]}} & wdata[64*n+:64]);
		end
		pick       = first[0] ? {W{1'b0}} : pick_o;
		pick_len   = first[0] ? len[6:0] : len_o;
		pick_addr  = first[0] ? addr[24:0] : addr_o;
		pick_wdata = first[0] ? wdata[63:0] : wdata_o;
	end

	// Whether a request may be taken is one flip-flop, set a clock ahead: the
	// take is the word every user waits for.  User 0 is told whether a request
	// of its own would be taken without having made it: take[0] is req[0] and
	// that, and the CPU, whose request comes late, need not send it here and
	// wait for the answer.
	reg  af_room;  // a request taken now has a place
	wire any_take = |first && af_room;
	assign take = first & {N{af_room}};
	reg sooner0;
	always @(*) begin
		sooner0 = 1'b0;
		for (k = 1; k < N; k = k + 1) if (place(k, last) < place(0, last)) sooner0 = sooner0 | ready[k];
	end
	// (while user 0 is under reset it asks for nothing that counts, so its
	// reset is left out of this)
	assign free0 = !mask[0] && rf_room && !sooner0 && af_room;

	//-----------------------------------------------------------------
	// From the take to the bridge
	//-----------------------------------------------------------------
	// A request with nothing in front of it goes to the bridge's queue as it
	// is taken (past), and from there to the bridge at once when the queue is
	// empty and nothing is being presented.  A read of a line of code and a
	// write into central memory go through the stage, where the tag of the
	// line's place is: into a queue of four first, and from its head into the
	// stage with the tag read in the same clock.  Whatever is taken while
	// something is in that queue or in the stage follows through them.
	localparam CW  = 1 + 7 + 25 + 64;  // write, words, address, data
	localparam AFD = 4;
	localparam AFA = $clog2(AFD);
	(* ramstyle = "MLAB, no_rw_check" *) reg [CW:0] af[0:AFD-1];  // (with the mark of code)
	reg [AFA-1:0] af_wr, af_rd;
	reg  [  AFA:0] af_n;
	wire [   CW:0] af_head = af[af_rd];
	wire [ICA-1:0] af_idx = af_head[64+4+:ICA];

	reg s_v, s_we, s_code;  // the stage holds a request
	reg  [  6:0] s_len;
	reg  [ 24:0] s_addr;
	reg  [ 63:0] s_data;
	wire         s_go;  // and it leaves this clock
	wire         s_free = !s_v || s_go;
	wire         s_load = s_free && (af_n != 0);
	wire         past;
	wire         af_push = any_take && !past;
	wire [AFA:0] af_n_nxt = af_n + {{AFA{1'b0}}, af_push} - {{AFA{1'b0}}, s_load};

	// the bridge's queue
	(* ramstyle = "MLAB, no_rw_check" *) reg [CW-1:0] cf[0:CF-1];
	reg [CA-1:0] cf_wr, cf_rd;
	reg  [  CA:0] cf_n;
	wire          cf_full = (cf_n == CF[CA:0]);
	wire          cf_empty = (cf_n == 0);
	wire [CW-1:0] cf_head = cf[cf_rd];

	// the lines kept
	(* ramstyle = "no_rw_check" *) reg [63:0] ic_data[0:ICL*16-1];
	(* ramstyle = "no_rw_check" *) reg [ICT:0] ic_tag[0:ICL-1];  // kept, and the tag
	reg [63:0] ic_q;
	reg [ICT:0] tag_q;  // the tag of the place of the stage's line, as it was when the stage took its request
	reg tag_unk;  // and a tag has been written to that place since
	reg ic_ready;  // the tags have been cleared since the reset
	reg [ICA-1:0] ic_clr;
	wire ic_on = KEPT && ic_ready;
	wire s_central = (s_addr[24:22] == 3'd0);
	wire s_line = !s_we && s_code && (s_len == 7'd16) && (s_addr[3:0] == 4'd0) && s_central;
	wire [ICA-1:0] s_idx = s_addr[4+:ICA];
	wire [ICT-1:0] s_tag = s_addr[4+ICA+:ICT];
	wire s_same = tag_q[ICT] && (tag_q[ICT-1:0] == s_tag);  // the place holds the stage's line
	wire s_kept = ic_on && s_line && !tag_unk && s_same;
	// reads answered from here and not yet delivered, by the places of their lines
	localparam IQ = 4;
	reg [ICA-1:0] icq[0:IQ-1];
	reg [$clog2(IQ)-1:0] icq_wr, icq_rd;
	reg  [$clog2(IQ):0] icq_n;
	// (the words of the DDR3 are handed on as they come, so a read does not
	// go there while one that is answered from here still waits in front)
	wire                icq_empty = (icq_n == 0);
	// lines on their way in: two reads at most, in order
	reg  [     ICA-1:0] fq_idx                                                    [0:1];
	reg  [     ICT-1:0] fq_tag                                                    [0:1];
	reg  [         1:0] fq_bad;  // a write went to the line since: it is not kept
	reg fq_wr, fq_rd;
	reg  [    1:0] fq_n;
	wire           fq_same = ((fq_n != 0) && (fq_idx[fq_rd] == s_idx)) || ((fq_n == 2'd2) && (fq_idx[!fq_rd] == s_idx));
	// a line that has come in whole and waits for the tags' write port
	reg            fc_v;
	reg  [ICA-1:0] fc_idx;
	reg  [ICT-1:0] fc_tag;

	// out of the stage
	wire s_ic_go = s_v && s_kept && (icq_n != IQ[$clog2(IQ):0]);  // answered from here
	wire s_cf_go = s_v && !s_kept && !cf_full && (s_we || icq_empty);  // to the bridge
	assign s_go = s_ic_go || s_cf_go;
	wire s_wr_out = s_cf_go && s_we && s_central;
	// a line read that goes to the DDR3 is kept when it has come, if a place
	// in the list is free, no line for the same place is on its way, and the
	// tag of the place is known
	wire alloc = s_cf_go && s_line && ic_on && !tag_unk && (fq_n != 2'd2) && !fq_same && !(fc_v && (fc_idx == s_idx));
	// The tags' write port: clearing after the reset; a write to a line that
	// is kept, or to a place whose tag is not known, or a line coming in for
	// a place that holds another; a line that has come in.
	wire fc_hit = s_wr_out && (fc_idx == s_idx) && (fc_tag == s_tag);
	wire tag_out = ic_on && ((s_wr_out && (tag_unk || s_same)) || (alloc && tag_q[ICT]));
	wire tag_in = fc_v && !tag_out && !fc_hit && ic_ready;
	wire tag_we = KEPT && (!ic_ready || tag_out || tag_in);
	wire [ICA-1:0] tag_wa = !ic_ready ? ic_clr : tag_out ? s_idx : fc_idx;
	wire [ICT:0] tag_wd = (!ic_ready || tag_out) ? {(ICT + 1) {1'b0}} : {1'b1, fc_tag};
	// (a write to a line that is on its way in)
	wire [1:0] fq_hit = {
		s_wr_out && (fq_idx[1] == s_idx) && (fq_tag[1] == s_tag),
		s_wr_out && (fq_idx[0] == s_idx) && (fq_tag[0] == s_tag)
	};

	// past the stage: what needs no tag, with nothing in front of it
	wire pick_central = (pick_addr[24:22] == 3'd0);
	wire pick_tagged = KEPT && pick_central && (pick_we || (pick_code && (pick_len == 7'd16) && (pick_addr[3:0] == 4'd0)));
	wire nothing_waits = !s_v && (af_n == 0) && icq_empty;
	assign past = any_take && !pick_tagged && nothing_waits && !cf_full;

	// to the bridge's queue, or to the bridge itself
	wire cf_push = s_cf_go || past;
	wire [CW-1:0] cf_word = s_v ? {s_we, s_len, s_addr, bswap(
		s_data
	)} : {pick_we, pick_len, pick_addr, bswap(
		pick_wdata
	)};
	reg h_valid, h_we;
	reg  [ 6:0] h_len;
	reg  [24:0] h_addr;
	reg  [63:0] h_din;
	reg  [ 8:0] drain;  // after reset, let any abandoned burst finish first
	wire        h_go = h_valid && !DDRAM_BUSY;  // the bridge takes it this clock
	wire        h_free = !h_valid || h_go;
	wire        to_head = cf_push && cf_empty && !h_valid && (drain == 9'd0);
	wire        cf_pop = h_free && !cf_empty && (drain == 9'd0);

	assign DDRAM_ADDR     = {4'b0011, h_addr};  // 0x3000_0000 + word * 8
	assign DDRAM_BURSTCNT = h_we ? 8'd1 : {1'b0, h_len};
	assign DDRAM_RD       = h_valid && !h_we;
	assign DDRAM_WE       = h_valid && h_we;
	assign DDRAM_DIN      = h_din;

	//-----------------------------------------------------------------
	// The reads taken and not yet answered, in order
	//-----------------------------------------------------------------
	// Whose, how many words, whether the words are wanted at all, whether
	// they come from the lines kept, and whether the line is kept as it comes.
	reg [ W-1:0] rf_owner[0:RF-1];
	(* ramstyle = "MLAB, no_rw_check" *)reg [   6:0] rf_len  [0:RF-1];
	reg [RF-1:0] rf_dead;
	reg [RF-1:0] rf_here;
	reg [RF-1:0] rf_keep;
	reg [RA-1:0] rf_wr, rf_rd, rf_dp;  // (rf_dp: the next to leave the stage, or to go past it)
	reg [RA:0] rf_n;
	reg [RA:0] rf_dn;  // of them, those that have left the stage
	reg [ 6:0] rf_cnt;  // words of the first delivered
	assign rf_room = (rf_n != RF[RA:0]);
	wire rd_out = (s_cf_go && !s_we) || s_ic_go || (past && !pick_we);

	// words of reads presented to the bridge since the reset and not yet come
	reg  [    9:0] outstanding;
	wire           word_back = DDRAM_DOUT_READY && (outstanding != 10'd0);
	wire           head_here = (rf_dn != 0) && rf_here[rf_rd];  // the first is answered from here
	wire           word_in = word_back && (rf_n != 0) && !head_here;
	wire           word_last = word_in && (rf_cnt + 7'd1 == rf_len[rf_rd]);
	wire [   63:0] word = bswap(DDRAM_DOUT);
	// A read answered from here: its line's words are asked for one a clock
	// and handed on the clock after.
	reg            ic_run;  // the words after the first are being asked for
	reg  [    3:0] ic_cnt;  // the next of them
	reg            ic_vq;  // ic_q holds a word of the line
	reg            ic_lastq;  // the last
	wire           ic_start = head_here && !ic_run && !ic_vq;
	wire           ic_ask = ic_start || ic_run;
	wire [    3:0] ic_word = ic_run ? ic_cnt : 4'd0;
	wire           rf_pop = word_last || (ic_vq && ic_lastq);
	// a line on its way in: its words into their place the clock after they
	// are handed on, from registers, which is soon enough: the line's tag is
	// written later still
	wire           ic_we = word_in && rf_keep[rf_rd];
	reg            ic_we_r;
	reg  [ICA+3:0] ic_wa_r;
	reg  [   63:0] rdata_b;  // the bridge's word
	reg  [   63:0] ic_r;  // a word of a line kept
	reg            rdata_here;  // the word for the users is that one
	wire           fill_done = word_last && rf_keep[rf_rd];
	reg  [  N-1:0] ack_last;

	generate
		if (KEPT) begin : g_kept
			always @(posedge clk) begin
				if (ic_we_r) ic_data[ic_wa_r] <= rdata_b;
				ic_q <= ic_data[{icq[icq_rd], ic_word}];
				if (tag_we) ic_tag[tag_wa] <= tag_wd;
				if (s_load) tag_q <= ic_tag[af_idx];
			end
		end else begin : g_none
			always @(posedge clk) begin
				ic_q  <= 64'd0;
				tag_q <= '0;
			end
		end
	endgenerate

	integer e;
	always @(posedge clk) begin
		ack      <= '0;
		ack_last <= '0;

		if (reset) begin
			af_wr       <= '0;
			af_rd       <= '0;
			af_n        <= '0;
			af_room     <= 1'b0;
			s_v         <= 1'b0;
			cf_wr       <= '0;
			cf_rd       <= '0;
			cf_n        <= '0;
			h_valid     <= 1'b0;
			drain       <= 9'd511;
			outstanding <= 10'd0;
			rf_wr       <= '0;
			rf_rd       <= '0;
			rf_dp       <= '0;
			rf_n        <= '0;
			rf_dn       <= '0;
			rf_cnt      <= 7'd0;
			rf_dead     <= '0;
			rf_here     <= '0;
			rf_keep     <= '0;
			icq_wr      <= '0;
			icq_rd      <= '0;
			icq_n       <= '0;
			fq_wr       <= 1'b0;
			fq_rd       <= 1'b0;
			fq_n        <= 2'd0;
			fq_bad      <= 2'b00;
			fc_v        <= 1'b0;
			ic_ready    <= 1'b0;
			ic_clr      <= '0;
			tag_unk     <= 1'b0;
			ic_run      <= 1'b0;
			ic_vq       <= 1'b0;
			mask        <= '0;
			last        <= '0;
		end else begin
			if (drain != 9'd0) drain <= drain - 9'd1;

			// a user's reset: the words still to come to it are not wanted any
			// more (a read taken in this clock gets its own mark below)
			for (e = 0; e < RF; e = e + 1) if (user_rst[rf_owner[e]]) rf_dead[e] <= 1'b1;

			// taken: past the stage, or into the queue in front of it.  (The
			// place at the end of a queue is written whenever there is one,
			// which keeps the take, the late word, off the memory's write
			// enable; it only counts when something was put there.)
			if (af_room) af[af_wr] <= {pick_code, pick_we, pick_len, pick_addr, pick_wdata};
			if (af_push) af_wr <= af_wr + 1'd1;
			if (s_load) af_rd <= af_rd + 1'd1;
			af_n    <= af_n_nxt;
			af_room <= (af_n_nxt != AFD[AFA:0]);

			// the stage, with the tag of its line's place: unknown if a tag is
			// written to that place while the stage takes or holds the request
			if (s_load) begin
				s_v                                   <= 1'b1;
				{s_code, s_we, s_len, s_addr, s_data} <= af_head;
				tag_unk                               <= tag_we && (tag_wa == af_idx);
			end else begin
				if (s_go) s_v <= 1'b0;
				if (s_v && tag_we && (tag_wa == s_idx)) tag_unk <= 1'b1;
			end

			// the bridge's queue, and the request presented to the bridge
			if (!cf_full) cf[cf_wr] <= cf_word;
			if (cf_push && !to_head) cf_wr <= cf_wr + 1'd1;
			if (cf_pop) cf_rd <= cf_rd + 1'd1;
			cf_n <= cf_n + {{CA{1'b0}}, cf_push && !to_head} - {{CA{1'b0}}, cf_pop};
			if (to_head) {h_valid, h_we, h_len, h_addr, h_din} <= {1'b1, cf_word};
			else if (h_free) begin
				h_valid                      <= cf_pop;
				{h_we, h_len, h_addr, h_din} <= cf_head;
			end
			outstanding <= outstanding + ((to_head && !cf_word[CW-1]) ? {3'd0, cf_word[CW-2-:7]} : (cf_pop && !cf_head[CW-1]) ? {3'd0, cf_head[CW-2-:7]} : 10'd0) - {9'd0, word_back};

			// a read taken: into the list of what comes back
			if (any_take) begin
				last <= pick;
				if (!pick_we) begin
					rf_owner[rf_wr] <= pick;
					rf_len[rf_wr]   <= pick_len;
					rf_dead[rf_wr]  <= user_rst[pick];
					rf_here[rf_wr]  <= 1'b0;
					rf_keep[rf_wr]  <= 1'b0;
					rf_wr           <= rf_wr + 1'd1;
				end
			end
			rf_n <= rf_n + {{RA{1'b0}}, any_take && !pick_we} - {{RA{1'b0}}, rf_pop};
			// a read leaves the stage, to the DDR3 or to be answered from the
			// lines kept, or goes past it
			if (rd_out) begin
				if (!past) begin
					rf_here[rf_dp] <= s_ic_go;
					rf_keep[rf_dp] <= alloc;
				end
				rf_dp <= rf_dp + 1'd1;
			end
			rf_dn <= rf_dn + {{RA{1'b0}}, rd_out} - {{RA{1'b0}}, rf_pop};

			// the tags are cleared after the reset, a place a clock
			if (!ic_ready) begin
				ic_clr <= ic_clr + 1'd1;
				if (&ic_clr) ic_ready <= 1'b1;
			end

			// the lines on their way in, and the one that has come
			if (tag_in || fc_hit) fc_v <= 1'b0;
			if (alloc) begin
				fq_idx[fq_wr] <= s_idx;
				fq_tag[fq_wr] <= s_tag;
				fq_bad[fq_wr] <= 1'b0;
				fq_wr         <= !fq_wr;
			end
			if (fq_hit[0]) fq_bad[0] <= 1'b1;
			if (fq_hit[1]) fq_bad[1] <= 1'b1;
			if (fill_done) begin
				fq_rd <= !fq_rd;
				if (!fq_bad[fq_rd] && !fq_hit[fq_rd] && (!fc_v || tag_in)) begin
					fc_v   <= 1'b1;
					fc_idx <= fq_idx[fq_rd];
					fc_tag <= fq_tag[fq_rd];
				end
			end
			fq_n <= fq_n + {1'b0, alloc} - {1'b0, fill_done};

			// reads answered from the lines kept: their places, in order, and
			// the words of the first
			if (s_ic_go) begin
				icq[icq_wr] <= s_idx;
				icq_wr      <= icq_wr + 1'd1;
			end
			if (ic_vq && ic_lastq) icq_rd <= icq_rd + 1'd1;
			icq_n    <= icq_n + {{$clog2(IQ) {1'b0}}, s_ic_go} - {{$clog2(IQ) {1'b0}}, ic_vq && ic_lastq};
			ic_vq    <= ic_ask;
			ic_lastq <= ic_ask && (ic_word == 4'd15);
			if (ic_ask) begin
				ic_cnt <= ic_word + 4'd1;
				ic_run <= (ic_word != 4'd15);
			end

			// a word for its user, unless the user has been reset since: from
			// the lines kept, or the bridge's
			if (ic_vq) begin
				if (!rf_dead[rf_rd]) begin
					ack[rf_owner[rf_rd]]      <= 1'b1;
					ack_last[rf_owner[rf_rd]] <= ic_lastq;
				end
				if (ic_lastq) rf_rd <= rf_rd + 1'd1;
			end
			if (word_in) begin
				if (!rf_dead[rf_rd]) begin
					ack[rf_owner[rf_rd]]      <= 1'b1;
					ack_last[rf_owner[rf_rd]] <= word_last;
				end
				rf_cnt <= word_last ? 7'd0 : rf_cnt + 7'd1;
				if (word_last) rf_rd <= rf_rd + 1'd1;
			end

			// users that hold their request until its acknowledge: a write is
			// acknowledged the clock after it is taken
			for (n = 0; n < N; n = n + 1)
			if (!STREAM[n]) begin
				if (take[n]) begin
					mask[n] <= 1'b1;
					if (we[n]) begin
						ack[n]      <= 1'b1;
						ack_last[n] <= 1'b1;
					end
				end
				if (ack[n] && ack_last[n]) mask[n] <= 1'b0;
				if (user_rst[n]) mask[n] <= 1'b0;
			end
		end
	end

	// The word itself is taken on the bridge's word alone, into a register
	// with nothing else in front of it, or is one of a line kept: every user
	// looks at it with its acknowledge.
	always @(posedge clk) begin
		if (DDRAM_DOUT_READY) rdata_b <= word;
		ic_r       <= ic_q;
		rdata_here <= ic_vq;
		ic_we_r    <= ic_we && !reset;
		ic_wa_r    <= {fq_idx[fq_rd], rf_cnt[3:0]};
	end
	always @(*) rdata = rdata_here ? ic_r : rdata_b;

`ifdef VERILATOR
	// the bridge hands over no word while a read answered from here is the
	// first: no read goes to the DDR3 behind one of those that still waits
	always @(posedge clk)
		if (!reset && word_back && head_here) begin
			$display("ddr3_ports: a word of the DDR3 while a kept line is being handed on");
			$finish;
		end
`endif

endmodule
