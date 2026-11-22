// -----------------------------------------------------------------------------
// tb_mac_gl.v -- portable self-checking testbench for mac_pipe
//
// Runs on Icarus Verilog against BOTH the RTL and the post-route SKY130
// gate-level netlist (compile with -DGL plus the sky130_fd_sc_hd cell models).
// It is written in plain Verilog-2005 so it works with the cell models; the
// richer SystemVerilog bench lives in the pipelined-mac-accelerator repo.
//
// Plusargs:
//   +vec=<file>   vectors from model/mac_model.cpp ("first last a b expected")
//   +seed=<n>     seed for the idle-gap randomization
//   +gap=<pct>    percent of cycles with in_valid=0 (0 = full throughput)
//   +vcd          dump waves to tb_mac_gl.vcd
//
// Inputs are driven and outputs are checked on the falling edge, so the bench
// is race-free with unit-delay gate models. Every out_valid is compared with
// the next expected result (acc_out and out_last) AND must arrive exactly LAT
// cycles after its sample was driven. X/Z on outputs, outputs with nothing
// expected, missing outputs and a hung pipeline are all errors.
// Prints "TEST PASSED" or "TEST FAILED".
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`ifndef CLK_PERIOD
  `define CLK_PERIOD 10
`endif

module tb_mac_gl;

    localparam DW   = 16;
    localparam AW   = 40;          // 2*DW + GUARD(8)
    localparam LAT  = 3;           // pipeline latency in cycles
    localparam MAXN = 65536;       // max samples per vector file

    reg                  clk = 1'b0;
    reg                  rst;
    reg                  in_valid, in_first, in_last;
    reg  signed [DW-1:0] in_a, in_b;
    wire                 out_valid, out_last;
    wire signed [AW-1:0] acc_out;

    always #(`CLK_PERIOD/2.0) clk = ~clk;

`ifdef GL
    // Post-route netlist: parameters are already elaborated (DW=16, GUARD=8).
    mac_pipe dut (
`else
    mac_pipe #(.DW(DW), .GUARD(8)) dut (
`endif
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_first(in_first), .in_last(in_last),
        .in_a(in_a), .in_b(in_b),
        .out_valid(out_valid), .out_last(out_last), .acc_out(acc_out)
    );

    // ---------------- vectors ----------------
    reg                  v_first [0:MAXN-1];
    reg                  v_last  [0:MAXN-1];
    reg  signed [DW-1:0] v_a     [0:MAXN-1];
    reg  signed [DW-1:0] v_b     [0:MAXN-1];
    reg  signed [AW-1:0] v_exp   [0:MAXN-1];
    integer              v_cyc   [0:MAXN-1];   // cycle each sample was driven

    integer n = 0;          // samples loaded
    integer wr = 0;         // next sample to drive
    integer rd = 0;         // next sample expected at the output
    integer cyc = 0;        // rising edges since reset was released
    integer n_err = 0, n_chk = 0, n_vec = 0;
    integer gap = 10, seed = 1, rs;
    integer last_drive_cyc = 0;
    reg [1023:0] vec_file;

    task load_vectors;
        integer fd, r, f, l;
        reg signed [63:0] a, b, e;
        begin
            fd = $fopen(vec_file, "r");
            if (fd == 0) begin
                $display("[tb] FATAL: cannot open vector file %0s", vec_file);
                $finish;
            end
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%d %d %d %d %d\n", f, l, a, b, e);
                if (r == 5) begin
                    if (n >= MAXN) begin
                        $display("[tb] FATAL: more than %0d samples", MAXN);
                        $finish;
                    end
                    v_first[n] = f[0];
                    v_last[n]  = l[0];
                    v_a[n]     = a[DW-1:0];
                    v_b[n]     = b[DW-1:0];
                    v_exp[n]   = e[AW-1:0];
                    n = n + 1;
                end
            end
            $fclose(fd);
            $display("[tb] loaded %0d samples from %0s", n, vec_file);
        end
    endtask

    function integer rnd;           // uniform 0..m-1 from the seeded stream
        input integer m;
        integer v;
        begin
            v = $random(rs);
            if (v < 0) v = -v;
            rnd = v % m;
        end
    endfunction

    always @(posedge clk) if (!rst) cyc <= cyc + 1;

    initial begin
        if (!$value$plusargs("vec=%s", vec_file)) vec_file = "vectors.txt";
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("gap=%d", gap)) gap = 10;
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_mac_gl.vcd");
            $dumpvars(0, tb_mac_gl);
        end
        rs = seed;
        load_vectors;

        rst = 1'b1; in_valid = 1'b0; in_first = 1'b0; in_last = 1'b0;
        in_a = 0; in_b = 0;
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // ------------- main loop: check, then drive, on every falling edge -------------
        while (rd < n && (wr < n || cyc - last_drive_cyc <= LAT + 100)) begin
            check_outputs;
            if (wr < n && !(gap > 0 && rnd(100) < gap)) begin
                in_valid = 1'b1;
                in_first = v_first[wr];
                in_last  = v_last[wr];
                in_a     = v_a[wr];
                in_b     = v_b[wr];
                v_cyc[wr] = cyc;
                last_drive_cyc = cyc;
                wr = wr + 1;
            end else begin
                in_valid = 1'b0;            // idle: garbage must be ignored
                in_first = rnd(2);
                in_last  = rnd(2);
                in_a     = $random(rs);
                in_b     = $random(rs);
            end
            @(negedge clk);
        end
        in_valid = 1'b0;
        if (rd < n) begin
            n_err = n_err + 1;
            $display("[tb] ERROR: timeout, %0d results never came out", n - rd);
        end
        // a few more cycles to catch stray outputs
        repeat (LAT + 3) begin
            check_outputs;
            @(negedge clk);
        end

        $display("[tb] seed=%0d gap=%0d%% driven=%0d checks=%0d vectors=%0d errors=%0d cycles=%0d",
                 seed, gap, wr, n_chk, n_vec, n_err, cyc);
        if (n_err == 0 && n_chk == n && n > 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

    task check_outputs;
        begin
            if (^out_valid === 1'bx) begin
                n_err = n_err + 1;
                if (n_err <= 10) $display("[tb] ERROR cycle %0d: out_valid is X/Z", cyc);
            end else if (out_valid) begin
                if (rd >= n || rd >= wr) begin
                    n_err = n_err + 1;
                    if (n_err <= 10) $display("[tb] ERROR cycle %0d: out_valid with no expected result", cyc);
                end else begin
                    n_chk = n_chk + 1;
                    if ((^acc_out === 1'bx) || (^out_last === 1'bx) ||
                        acc_out !== v_exp[rd] || out_last !== v_last[rd]) begin
                        n_err = n_err + 1;
                        if (n_err <= 10)
                            $display("[tb] MISMATCH sample %0d cycle %0d: acc_out=%0d (exp %0d) out_last=%b (exp %b)",
                                     rd, cyc, acc_out, v_exp[rd], out_last, v_last[rd]);
                    end else if (cyc - v_cyc[rd] != LAT) begin
                        n_err = n_err + 1;
                        if (n_err <= 10)
                            $display("[tb] LATENCY sample %0d: %0d cycles (exp %0d)", rd, cyc - v_cyc[rd], LAT);
                    end
                    if (v_last[rd]) n_vec = n_vec + 1;
                    rd = rd + 1;
                end
            end
        end
    endtask

endmodule
