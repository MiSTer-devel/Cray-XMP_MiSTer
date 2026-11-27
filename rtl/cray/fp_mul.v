//******************************************
//       Floating Point Multiply Unit
//******************************************
//
// Floating product of two Cray floating point words (instructions 064 to 067
// and 160 to 167).  A pure pipeline: operands in during one clock, the result
// out seven clocks later, a new operation every clock.  The first of the seven
// clocks only takes the operands into registers of the unit's own: where they
// come from is the far end of the longest way in the CPU, and nothing more
// should be asked of it.
//
//   i_kind 0  064  full product
//          1  065  half-precision rounded product
//          2  066  rounded product
//          3  067  reciprocal iteration, 2 - a*b
//
// The multiplier is the truncated pyramid of the Cray manuals: the symmetric
// unit the CRAY-1 had from 1980 (change packet E-01 of its manual), which the
// X-MP manuals describe in the same words (HR-0097B figure 4-10 and page 4-30).
// The reference model is tools/crates/fp/src/mul.rs, which this unit matches
// bit for bit.  With the coefficients as fractions,
// the logical product of bit 2^-p of one and bit 2^-q of the other belongs to
// column p+q.  Only columns 2 to 56 are formed; everything to the right is
// never generated, so each row of the pyramid is cut off at 2^-56.  A constant
// of nine units of 2^-56 makes up for the average of what was cut, and the
// rounded forms add round bits in the same adder.
//
// The pyramid is not built row by row here.  With the coefficients as whole
// numbers A and B of 48 bits it is the logical products of bit i of A and
// bit j of B with i + j of 40 or more, in units of 2^40: the whole product
// A * B less the corner T of the products with i + j below 40.  Every product
// outside the corner is a multiple of 2^40, so the low 40 bits of T are those
// of A * B, and the pyramid is (A * B) / 2^40 less T / 2^40, both without
// their fractions.  T / 2^40 is 39 at most.  The multiplications are made by
// the chip's multipliers: A * B from four of 24 by 24, and the corner from
// one of 20 by 20 (the low halves of the low 40 bits, whose products all lie
// in it) and two corners of half the size, each one of 10 by 10 and two
// corners of 10 bits, which are added up from their rows.  The rows take two
// clocks: three sums of rows beside the multipliers, their sum in the clock
// after, and the corner itself in the clock after that, when the product
// stands ready; it is taken off in the last add, with the constants.
//
// Exponents: both zero is an integer multiply (no normalising shift, exponent
// zero); exactly one zero gives an all-zero word; an operand exponent of 060000
// or more, or an unshifted product exponent that reaches 060000, is a range
// error; a product exponent below 020000 gives an all-zero word.

// (the attribute has Quartus make every multiplication here in a DSP block)
(* multstyle = "dsp" *)
module fp_mul (
	input  wire        clk,
	input  wire [63:0] i_a,
	input  wire [63:0] i_b,
	input  wire [ 1:0] i_kind,
	output reg  [63:0] o_result,
	output reg         o_range_err,
	output wire [63:0] o_early       // the result during the clock before o_result has it
);

	localparam [14:0] EXP_BIAS     = 15'o40000;
	localparam [14:0] EXP_MIN      = 15'o20000;
	localparam [14:0] EXP_OVERFLOW = 15'o60000;

	localparam [1:0] K_FULL = 2'd0, K_HALF = 2'd1, K_ROUND = 2'd2, K_2M = 2'd3;

	// ---- stage 1: the operands ----
	// (these registers stay where they are: retiming must not move the unit's
	// first sums in front of them, onto the way the operands come)
	(* dont_retime *) reg [63:0] a, b;
	(* dont_retime *) reg [1:0] kind;
	always @(posedge clk) begin
		a    <= i_a;
		b    <= i_b;
		kind <= i_kind;
	end

	// ---- the pyramid, in units of 2^-56 ----
	wire [47:0] a_coef = a[47:0];
	wire [47:0] b_coef = b[47:0];

	// the corner of two 10-bit numbers: the products of bit i of x and bit j of
	// y with i + j below 10.  Here the rows from to to of it: the rows of the
	// bits of x with those numbers.
	function [13:0] corner10;
		input [9:0] x;
		input [9:0] y;
		input integer from;
		input integer to;
		integer        i;
		reg     [13:0] sum;
		reg     [ 9:0] low;
		begin
			sum = 14'd0;
			for (i = 0; i < 10; i = i + 1) begin
				low = y & (10'h3FF >> i);
				if ((i >= from) && (i <= to) && x[i]) sum = sum + ({4'd0, low} << i);
			end
			corner10 = sum;
		end
	endfunction

	// stage 2: the multipliers
	reg [47:0] p_hh, p_hl, p_lh, p_ll;  // A * B in four pieces
	reg [39:0] m20;  // of the corner: the low 20 bits of each
	reg [19:0] m10_a, m10_b;  // and of its two half corners, bits 39-20 of one and 19-0 of the other
	// (of each corner of 10 bits: rows 0 to 3, 4 to 6 and 7 to 9)
	reg [13:0] r_a0[0:2];
	reg [13:0] r_a1[0:2];
	reg [13:0] r_b0[0:2];
	reg [13:0] r_b1[0:2];
	always @(posedge clk) begin
		p_hh    <= a_coef[47:24] * b_coef[47:24];
		p_hl    <= a_coef[47:24] * b_coef[23:0];
		p_lh    <= a_coef[23:0] * b_coef[47:24];
		p_ll    <= a_coef[23:0] * b_coef[23:0];
		m20     <= a_coef[19:0] * b_coef[19:0];
		m10_a   <= a_coef[29:20] * b_coef[9:0];
		m10_b   <= a_coef[9:0] * b_coef[29:20];
		r_a0[0] <= corner10(a_coef[39:30], b_coef[9:0], 0, 3);
		r_a0[1] <= corner10(a_coef[39:30], b_coef[9:0], 4, 6);
		r_a0[2] <= corner10(a_coef[39:30], b_coef[9:0], 7, 9);
		r_a1[0] <= corner10(a_coef[29:20], b_coef[19:10], 0, 3);
		r_a1[1] <= corner10(a_coef[29:20], b_coef[19:10], 4, 6);
		r_a1[2] <= corner10(a_coef[29:20], b_coef[19:10], 7, 9);
		r_b0[0] <= corner10(a_coef[19:10], b_coef[29:20], 0, 3);
		r_b0[1] <= corner10(a_coef[19:10], b_coef[29:20], 4, 6);
		r_b0[2] <= corner10(a_coef[19:10], b_coef[29:20], 7, 9);
		r_b1[0] <= corner10(a_coef[9:0], b_coef[39:30], 0, 3);
		r_b1[1] <= corner10(a_coef[9:0], b_coef[39:30], 4, 6);
		r_b1[2] <= corner10(a_coef[9:0], b_coef[39:30], 7, 9);
	end

	// stage 3: the product from bit 40 up, and the corners of 10 bits from
	// their rows.  The pieces p_hh and p_ll do not overlap, so the product
	// from bit 24 up is one sum of three.
	wire [71:0] p_sum = {p_hh, p_ll[47:24]} + {24'd0, p_hl} + {24'd0, p_lh};
	reg  [55:0] s3_product;
	reg  [39:0] s3_m20;
	reg [19:0] s3_m10_a, s3_m10_b;
	reg [13:0] t10_a0, t10_a1, t10_b0, t10_b1;
	always @(posedge clk) begin
		s3_product <= p_sum[71:16];
		s3_m20     <= m20;
		s3_m10_a   <= m10_a;
		s3_m10_b   <= m10_b;
		t10_a0     <= r_a0[0] + r_a0[1] + r_a0[2];
		t10_a1     <= r_a1[0] + r_a1[1] + r_a1[2];
		t10_b0     <= r_b0[0] + r_b0[1] + r_b0[2];
		t10_b1     <= r_b1[0] + r_b1[1] + r_b1[2];
	end

	// stage 4: what the corner takes from the product, which waits a clock
	wire [24:0] half_a = {5'd0, s3_m10_a} + {{1'b0, t10_a0} + {1'b0, t10_a1}, 10'd0};
	wire [24:0] half_b = {5'd0, s3_m10_b} + {{1'b0, t10_b0} + {1'b0, t10_b1}, 10'd0};
	wire [45:0] corner = {6'd0, s3_m20} + {{1'b0, half_a} + {1'b0, half_b}, 20'd0};
	reg  [55:0] s4_product;
	reg  [ 5:0] s4_corner;
	always @(posedge clk) begin
		s4_product <= s3_product;
		s4_corner  <= corner[45:40];
	end

	// ---- sign, kind and exponent beside the pyramid ----
	// The exponent of the product and its tests are formed here, in the clocks the
	// pyramid takes, so that nothing is left for the end but to choose.  The tests
	// are made on the exponent before the normalising shift.
	wire        [14:0] ea = a[62:48];
	wire        [14:0] eb = b[62:48];
	wire signed [16:0] e = $signed({2'b00, ea}) + $signed({2'b00, eb}) - $signed({2'b00, EXP_BIAS});

	reg c2_neg, c3_neg, c4_neg, c5_neg, c6_neg;
	reg [1:0] c2_kind, c3_kind, c4_kind, c5_kind;
	reg c2_integer, c3_integer, c4_integer, c5_integer, c6_integer;
	reg c2_one_zero, c3_one_zero, c4_one_zero, c5_one_zero, c6_one_zero;
	reg        c2_operand_ovf;
	reg [16:0] c2_e;
	reg c3_ovf, c4_ovf, c5_ovf, c6_ovf;
	reg c3_unf, c4_unf, c5_unf, c6_unf;
	reg [14:0] c3_exp, c4_exp, c5_exp;  // the exponent if the product needs no shift
	reg [14:0] c3_exp_m1, c4_exp_m1, c5_exp_m1;  // and if it is shifted one place
	always @(posedge clk) begin
		c2_neg         <= a[63] ^ b[63];
		c2_kind        <= kind;
		c2_integer     <= (ea == 15'd0) && (eb == 15'd0);
		c2_one_zero    <= (ea == 15'd0) != (eb == 15'd0);
		c2_operand_ovf <= (ea >= EXP_OVERFLOW) || (eb >= EXP_OVERFLOW);
		c2_e           <= e;

		c3_neg      <= c2_neg;
		c3_kind     <= c2_kind;
		c3_integer  <= c2_integer;
		c3_one_zero <= c2_one_zero;
		c3_ovf      <= c2_operand_ovf || ($signed(c2_e) >= $signed({2'b00, EXP_OVERFLOW}));
		c3_unf      <= ($signed(c2_e) < $signed({2'b00, EXP_MIN}));
		c3_exp      <= c2_e[14:0];
		c3_exp_m1   <= c2_e[14:0] - 15'd1;

		c4_neg      <= c3_neg;
		c4_kind     <= c3_kind;
		c4_integer  <= c3_integer;
		c4_one_zero <= c3_one_zero;
		c4_ovf      <= c3_ovf;
		c4_unf      <= c3_unf;
		c4_exp      <= c3_exp;
		c4_exp_m1   <= c3_exp_m1;

		c5_neg      <= c4_neg;
		c5_kind     <= c4_kind;
		c5_integer  <= c4_integer;
		c5_one_zero <= c4_one_zero;
		c5_ovf      <= c4_ovf;
		c5_unf      <= c4_unf;
		c5_exp      <= c4_exp;
		c5_exp_m1   <= c4_exp_m1;

		c6_neg      <= c5_neg;
		c6_integer  <= c5_integer;
		c6_one_zero <= c5_one_zero;
		c6_ovf      <= c5_ovf;
		c6_unf      <= c5_unf;
	end

	// stage 5: the last add: the pyramid, which is the product less the corner,
	// with the constants.  The compensation is 9; the round
	// bits are 2^-50 and 2^-51 (066) or 2^-31 and 2^-32 (065).  For 067 the unit
	// forms 198 minus the pyramid sum, which is its complement and 199.  That is
	// what Cray's own simulation of the unit comes to (see TwoMinus::Cray in
	// mul.rs): it adds one bits at 2^-2 to 2^-48 and 2^-51 + 2^-52 to the sum and
	// its constant, then complements everything below 2^-1.
	// The corner comes off as its complement and one more, the one in the
	// constant; under the complement of 067 it is added instead.
	reg  [55:0] s5_out;
	reg  [55:0] konst;
	wire        two_minus = (c4_kind == K_2M);
	always @(*) begin
		case (c4_kind)
			K_HALF:  konst = 56'd10 + (56'd1 << 25) + (56'd1 << 24);
			K_ROUND: konst = 56'd10 + (56'd1 << 6) + (56'd1 << 5);
			K_2M:    konst = 56'd199;
			K_FULL:  konst = 56'd10;
		endcase
	end
	always @(posedge clk)
		s5_out <= (two_minus ? ~s4_product : s4_product) + konst + (two_minus ? {50'd0, s4_corner} : ~{50'd0, s4_corner});

	// stage 6: normalise by at most one place, cut the half-precision result to 29
	// bits, and take the exponent that goes with the shift
	wire        no_shift = c5_integer || s5_out[55];
	wire [47:0] coef_full = no_shift ? s5_out[55:8] : s5_out[54:7];
	reg  [47:0] s6_coef;
	reg  [14:0] s6_exp;
	always @(posedge clk) begin
		s6_coef <= (c5_kind == K_HALF) ? {coef_full[47:19], 19'd0} : coef_full;
		s6_exp  <= no_shift ? c5_exp : c5_exp_m1;
	end

	// stage 7: pick the result
	reg [63:0] pick;
	reg        pick_err;
	always @* begin
		pick     = {c6_neg, s6_exp, s6_coef};
		pick_err = 1'b0;
		if (c6_one_zero) pick = 64'd0;
		else if (c6_integer) pick = {c6_neg, 15'd0, s6_coef};
		else if (c6_ovf) begin
			pick     = {c6_neg, EXP_OVERFLOW, s6_coef};
			pick_err = 1'b1;
		end else if (c6_unf) pick = 64'd0;
	end
	always @(posedge clk) begin
		o_result    <= pick;
		o_range_err <= pick_err;
	end

	assign o_early = pick;

endmodule
