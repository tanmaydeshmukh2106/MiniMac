// =============================================================================
// tb_simple.sv — Smoke-test Testbench for MiniMAC
// =============================================================================
// Test case (INT8, N=4):
//   Weight matrix  : W[0][0] = 5, all other weights = 0
//   Activation     : act_in[0] = 3 when a_col=0, all other = 0
//
// Expected output:
//   Only PE[0][0] contributes: weight=5, activation=3 → 5×3 = 15
//   psum_out[0] = 15
//   psum_out[1] = psum_out[2] = psum_out[3] = 0
//
// What this testbench checks:
//   1. FSM transitions correctly (busy asserts, output_valid asserts on time)
//   2. psum_out has no X/Z when output_valid is high
//   3. psum_out[0] == 15, psum_out[1..3] == 0
//   4. DUT returns to IDLE (busy deasserts) after output_ready handshake
// =============================================================================

`timescale 1ns/1ps

module tb_simple;

    // ── Parameters ────────────────────────────────────────────────────────────
    localparam int N      = 4;
    localparam int DATA_W = 8;
    localparam int PSUM_W = 32;

    // ── DUT signals ───────────────────────────────────────────────────────────
    logic clk, rst_n;
    logic start, busy, output_valid, output_ready;

    logic [$clog2(N*N)-1:0]  w_addr;
    logic [DATA_W-1:0]        w_data;

    logic [$clog2(N)-1:0]    a_col;
    logic [DATA_W-1:0]        a_data [N];

    logic [PSUM_W-1:0]        psum_out [N];

    // ── DUT instantiation ─────────────────────────────────────────────────────
    minimac_top #(
        .N         (N),
        .PRECISION ("INT8")
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .busy         (busy),
        .output_valid (output_valid),
        .output_ready (output_ready),
        .w_addr       (w_addr),
        .w_data       (w_data),
        .a_col        (a_col),
        .a_data       (a_data),
        .psum_out     (psum_out)
    );

    // ── Clock: 10 ns period (100 MHz) ─────────────────────────────────────────
    initial clk = 0;
    always  #5 clk = ~clk;

    // ── Weight SRAM model ─────────────────────────────────────────────────────
    // W[0][0] = 5  (w_addr = row*N + col = 0*4+0 = 0)
    // All other weights = 0
    always_comb
        w_data = (w_addr == '0) ? 8'd5 : 8'd0;

    // ── Activation SRAM model ─────────────────────────────────────────────────
    // a_data[0] = 3 when streaming column 0; everything else = 0
    always_comb begin
        for (int r = 0; r < N; r++)
            a_data[r] = (a_col == '0 && r == 0) ? 8'd3 : 8'd0;
    end

    // ── Debug monitor — prints PE[0][0] internals every cycle during operation ─
    always @(posedge clk) begin
        if (busy) begin
            $display("[%0t ns] w_addr=%0d w_data=%0d weight_ld00=%0b | a_col=%0d act_in0=%0d | psum_out0=%0d",
                $time,
                w_addr, w_data,
                dut.u_controller.weight_ld[0][0],
                a_col, dut.act_in[0],
                psum_out[0]);
        end
    end

    // ── Main stimulus + checker ───────────────────────────────────────────────
    int pass_cnt = 0;
    int fail_cnt = 0;

    initial begin
        // Waveform dump (EDA Playground / Questa)
        $dumpfile("minimac_tb.vcd");
        $dumpvars(0, tb_simple);

        // Initialise
        rst_n        = 0;
        start        = 0;
        output_ready = 0;

        // Hold reset for 4 cycles
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ── Sanity: DUT should be idle ────────────────────────────────────────
        check("busy LOW before start", !busy);

        // ── Pulse start ───────────────────────────────────────────────────────
        $display("\n[%0t ns] Asserting start", $time);
        start = 1;
        @(posedge clk);
        start = 0;
        @(posedge clk);

        // busy should be high now
        check("busy HIGH after start", busy);

        // ── Wait for output_valid (timeout = 200 cycles) ──────────────────────
        begin : wait_valid
            automatic int timeout = 200;
            while (!output_valid && timeout > 0) begin
                @(posedge clk);
                timeout--;
            end
            if (timeout == 0) begin
                $display("[%0t ns] ** TIMEOUT waiting for output_valid **", $time);
                fail_cnt++;
                $finish;
            end
        end

        $display("[%0t ns] output_valid asserted", $time);

        // ── Check X/Z on psum_out ─────────────────────────────────────────────
        for (int c = 0; c < N; c++) begin
            if (^psum_out[c] === 1'bx)
                check_fail($sformatf("psum_out[%0d] has X/Z", c));
            else
                pass_cnt++;
        end

        // ── Check actual values ───────────────────────────────────────────────
        $display("\n--- Output Results ---");
        check_val("psum_out[0]", psum_out[0], 32'd15);
        check_val("psum_out[1]", psum_out[1], 32'd0 );
        check_val("psum_out[2]", psum_out[2], 32'd0 );
        check_val("psum_out[3]", psum_out[3], 32'd0 );

        // ── Handshake: acknowledge result ─────────────────────────────────────
        output_ready = 1;
        @(posedge clk);
        output_ready = 0;
        @(posedge clk);

        // DUT should be back in IDLE
        check("busy LOW after handshake", !busy);
        check("output_valid LOW after handshake", !output_valid);

        // ── Summary ───────────────────────────────────────────────────────────
        $display("\n==============================");
        if (fail_cnt == 0)
            $display("  ALL %0d CHECKS PASSED  ✓", pass_cnt);
        else
            $display("  PASSED: %0d  FAILED: %0d", pass_cnt, fail_cnt);
        $display("==============================\n");

        #20;
        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────────────────────
    initial begin
        #50000;
        $display("** GLOBAL TIMEOUT **");
        $finish;
    end

    // ── Helper tasks ──────────────────────────────────────────────────────────
    task automatic check(input string name, input logic cond);
        if (cond) begin
            $display("  PASS: %s", name);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s", name);
            fail_cnt++;
        end
    endtask

    task automatic check_val(
        input string           name,
        input logic [PSUM_W-1:0] got,
        input logic [PSUM_W-1:0] exp
    );
        $display("  %s = %0d  (expected %0d)  %s",
                 name, got, exp, (got === exp) ? "PASS" : "** FAIL **");
        if (got === exp) pass_cnt++;
        else             fail_cnt++;
    endtask

    task automatic check_fail(input string msg);
        $display("  FAIL: %s", msg);
        fail_cnt++;
    endtask

endmodule : tb_simple
