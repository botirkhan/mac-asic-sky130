// -----------------------------------------------------------------------------
// mac_pipe.sv -- 3-stage pipelined signed multiply-accumulate (MAC) unit
//
//   Stage 1 (S1): register operands a, b and the control bits   (DSP A/B regs)
//   Stage 2 (S2): register the full-precision product a*b       (DSP M reg)
//   Stage 3 (S3): accumulate: acc <= first ? p : acc + p        (DSP P reg)
//
// Framing: a dot product is a run of valid samples. The sample with
// in_first=1 restarts the accumulator (acc = a*b instead of acc + a*b); the
// sample with in_last=1 marks the end, and out_last flags the final result.
// A single-sample vector sets in_first and in_last together.
//
// Accumulator width: AW = 2*DW + GUARD. With the defaults (DW=16, GUARD=8,
// AW=40) the worst-case product is (-2^15)*(-2^15) = 2^30, and a signed 40-bit
// register holds up to 2^39 - 1, so 511 worst-case products sum without
// overflow. Beyond that the result wraps modulo 2^AW, exactly like the C++
// golden model (the testbench checks this case too). AW must be >= 2*DW.
//
// The datapath has no reset and every stage has a clock enable driven by the
// valid bit, so Vivado can pack the whole datapath into one DSP48E1
// (AREG/BREG=1, MREG=1, PREG=1, OPMODE selecting P or 0 for the Z mux).
// Only the three valid/first/last control pipelines are reset.
// -----------------------------------------------------------------------------
module mac_pipe #(
    parameter int DW    = 16,            // operand width (signed)
    parameter int GUARD = 8,             // guard bits above the product width
    parameter int AW    = 2*DW + GUARD   // accumulator width (signed)
) (
    input  logic                 clk,
    input  logic                 rst,        // synchronous, active high

    // input stream
    input  logic                 in_valid,
    input  logic                 in_first,   // restart accumulation with this sample
    input  logic                 in_last,    // last sample of the vector
    input  logic signed [DW-1:0] in_a,
    input  logic signed [DW-1:0] in_b,

    // output stream (one result per accepted sample, 3 cycles later)
    output logic                 out_valid,
    output logic                 out_last,   // acc_out is a finished dot product
    output logic signed [AW-1:0] acc_out
);

    localparam int PW = 2*DW;            // product width

    // ---------------- control pipeline (reset) ----------------
    logic v1, v2, v3;
    logic f1, f2;
    logic l1, l2, l3;

    always_ff @(posedge clk) begin
        if (rst) begin
            v1 <= 1'b0;  v2 <= 1'b0;  v3 <= 1'b0;
        end else begin
            v1 <= in_valid;
            v2 <= v1;
            v3 <= v2;
        end
    end

    always_ff @(posedge clk) begin
        if (in_valid) begin f1 <= in_first; l1 <= in_last; end
        if (v1)       begin f2 <= f1;       l2 <= l1;      end
        if (v2)       begin                 l3 <= l2;      end
    end

    // ---------------- datapath (no reset, clock-enabled) ----------------
    logic signed [DW-1:0] a1, b1;        // S1: operand registers
    logic signed [PW-1:0] p2;            // S2: product register
    logic signed [AW-1:0] acc3;          // S3: accumulator register

    always_ff @(posedge clk) begin
        if (in_valid) begin
            a1 <= in_a;
            b1 <= in_b;
        end
    end

    always_ff @(posedge clk) begin
        if (v1)
            p2 <= a1 * b1;               // full-precision signed product
    end

    // sign-extend the product to the accumulator width
    logic signed [AW-1:0] p2_ext;
    assign p2_ext = {{(AW-PW){p2[PW-1]}}, p2};   // explicit sign extension (portable to Yosys)

    // Bug-injection hooks for the mutation test (scripts/run_tests.py --mutate).
    // They are only compiled in simulation when the matching macro is defined.
`ifdef MUTATE_NO_FIRST
    initial acc3 = '0;                   // start clean so only the logic bug shows
    always @(posedge clk)
        if (v2) acc3 <= acc3 + p2_ext;   // bug: accumulator never restarts
`elsif MUTATE_NO_CE
    always @(posedge clk)                // bug: stage 3 ignores valid, so idle
        acc3 <= f2 ? p2_ext : (acc3 + p2_ext);  // cycles re-add the stale product
`else
    always_ff @(posedge clk) begin
        if (v2)
            acc3 <= f2 ? p2_ext : (acc3 + p2_ext);
    end
`endif

    assign out_valid = v3;
    assign out_last  = v3 & l3;
    assign acc_out   = acc3;

endmodule
