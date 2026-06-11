// =============================================================================
// tb_top.sv — UVM Testbench Top Module for MiniMAC
// =============================================================================
// Instantiates:
//   - Clock generator
//   - minimac_if (interface carrying all DUT signals + SRAM model)
//   - minimac_top DUT
//   - UVM config_db set + run_test
//
// Compile order for EDA Playground (Riviera-PRO):
//   1. pe.sv
//   2. sys_array.sv
//   3. controller.sv
//   4. minimac_top.sv
//   5. minimac_if.sv
//   6. minimac_pkg.sv
//   7. tb_top.sv  ← this file
// =============================================================================

`timescale 1ns/1ps

import uvm_pkg::*;
`include "uvm_macros.svh"
import minimac_pkg::*;

module tb_top;

    localparam int N = 4;

    // ── Clock ─────────────────────────────────────────────────────────────────
    logic clk;
    initial  clk = 0;
    always #5 clk = ~clk;   // 100 MHz

    // ── Interface instance ────────────────────────────────────────────────────
    minimac_if #(.N(N)) mif (.clk(clk));

    // ── DUT ───────────────────────────────────────────────────────────────────
    minimac_top #(
        .N        (N),
        .PRECISION("INT8")
    ) dut (
        .clk          (clk),
        .rst_n        (mif.rst_n),
        .start        (mif.start),
        .busy         (mif.busy),
        .output_valid (mif.output_valid),
        .output_ready (mif.output_ready),
        .w_addr       (mif.w_addr),
        .w_data       (mif.w_data),
        .a_col        (mif.a_col),
        .a_data       (mif.a_data),
        .psum_out     (mif.psum_out)
    );

    // ── UVM kickoff ───────────────────────────────────────────────────────────
    initial begin
        // Register virtual interface so driver/monitor can get it
        uvm_config_db #(virtual minimac_if #(N))::set(null, "*", "vif", mif);
        // Start the test
        run_test("minimac_test");
    end

endmodule : tb_top
