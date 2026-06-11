// =============================================================================
// minimac_if.sv — SystemVerilog Interface for MiniMAC DUT
// =============================================================================
// Bundles all DUT signals into one interface so the UVM driver/monitor
// can access them through a virtual interface handle.
//
// Also contains the SRAM model logic:
//   w_mem[N*N] — flat weight memory (row-major), written by driver
//   a_mem[N]   — activation vector for column 0, written by driver
//   w_data and a_data respond combinationally to w_addr and a_col
// =============================================================================

`timescale 1ns/1ps

interface minimac_if #(int N = 4) (input logic clk);

    // ── DUT ports ─────────────────────────────────────────────────────────────
    logic        rst_n;
    logic        start;
    logic        busy;
    logic        output_valid;
    logic        output_ready;

    logic [$clog2(N*N)-1:0] w_addr;
    logic [7:0]             w_data;
    logic [$clog2(N)-1:0]   a_col;
    logic [7:0]             a_data  [N];
    logic [31:0]            psum_out [N];

    // ── SRAM backing arrays — written by driver before each transaction ───────
    logic [7:0] w_mem [N*N];   // weight memory: w_mem[row*N + col]
    logic [7:0] a_mem [N];     // activation vector (single column, col 0)

    // ── Combinational SRAM response ───────────────────────────────────────────
    // Weight SRAM: 0-cycle read latency
    assign w_data = w_mem[w_addr];

    // Activation SRAM: row-skewed delivery.
    // Row r's activation is presented only when a_col == r.
    // The controller increments a_col each cycle (0→N-1) during STREAM_ACT,
    // so act[r] arrives at PE row r on cycle r — naturally staggered.
    // This aligns each row's activation with the partial sum arriving from
    // the PE above, enabling correct W.T @ act accumulation through the
    // single-stage systolic array.
    always_comb begin
        for (int r = 0; r < N; r++)
            a_data[r] = (a_col == ($clog2(N))'(r)) ? a_mem[r] : 8'h0;
    end

endinterface : minimac_if
