// =============================================================================
// minimac_top.sv — Top-Level Wrapper for MiniMAC AI Accelerator
// =============================================================================
// Description:
//   Instantiates and wires together:
//     - controller   : FSM that sequences weight loading and activation streaming
//     - sys_array    : NxN systolic array of PE tiles (weight-stationary)
//
//   The controller drives weight_ld, weight_in, and act_in into the array.
//   The array drives psum_out, which is exposed directly as the top-level output.
//
//   External memory interfaces are passed through transparently:
//     - Weight SRAM  : host provides w_data in response to w_addr
//     - Activation SRAM: host provides a_data[N] in response to a_col
//
// Parameters:
//   N         — array dimension (default 4 → 4×4 array)
//   PRECISION — "INT8" or "FP16"
//
// Port widths:
//   DATA_W = 8  (INT8) or 16 (FP16)
//   PSUM_W = 32 always
//
// External interface summary:
//
//   ┌─────────────────────────────────────────────────────────┐
//   │                    minimac_top                          │
//   │                                                         │
//   │  start ──►  controller ──► weight_ld/weight_in ──►     │
//   │  busy  ◄──              ──► act_in              ──► sys_array ──► psum_out
//   │  output_valid ◄──       ◄── (output_ready)              │
//   │                                                         │
//   │  w_addr ──► [weight SRAM — external]  ──► w_data        │
//   │  a_col  ──► [activation SRAM — external] ──► a_data[N]  │
//   └─────────────────────────────────────────────────────────┘
//
// Typical operation sequence:
//   1. Assert start for one cycle
//   2. Supply w_data in response to each w_addr (N² cycles)
//   3. Supply a_data[N] in response to each a_col (N cycles)
//   4. Wait for output_valid; assert output_ready to acknowledge
//   5. Read psum_out[N] — one dot-product result per column
// =============================================================================

`timescale 1ns/1ps

module minimac_top #(
    parameter int    N         = 4,
    parameter string PRECISION = "INT8",
    parameter int    DATA_W    = (PRECISION == "FP16") ? 16 : 8,
    parameter int    PSUM_W    = 32
) (
    input  logic clk,
    input  logic rst_n,

    // ── Host handshake ────────────────────────────────────────────────────
    input  logic        start,          // pulse high 1 cycle to begin
    output logic        busy,           // high throughout operation
    output logic        output_valid,   // result ready in psum_out
    input  logic        output_ready,   // accept result, return to IDLE

    // ── Weight SRAM interface (pass-through from controller) ──────────────
    output logic [$clog2(N*N)-1:0]  w_addr,      // weight read address
    input  logic [DATA_W-1:0]        w_data,      // weight read data

    // ── Activation SRAM interface (pass-through from controller) ──────────
    output logic [$clog2(N)-1:0]    a_col,       // activation column index
    input  logic [DATA_W-1:0]        a_data [N],  // one activation per row

    // ── Array output ──────────────────────────────────────────────────────
    output logic [PSUM_W-1:0]        psum_out [N] // final dot-product per column
);

    // -------------------------------------------------------------------------
    // Internal interconnect: controller → sys_array
    // -------------------------------------------------------------------------
    logic                  weight_ld  [N][N];
    logic [DATA_W-1:0]     weight_in  [N][N];
    logic [DATA_W-1:0]     act_in     [N];

    // -------------------------------------------------------------------------
    // Output accumulator
    // -------------------------------------------------------------------------
    // The single-stage PE + row-skewed activation causes each column c's correct
    // result to appear at psum_raw[c] for exactly one clock cycle:
    //   cycle STREAM_ACT[N-1] + 0  →  psum_raw[0] = correct sum for col 0
    //   cycle ACCUM[0]             →  psum_raw[1] = correct sum for col 1
    //   ...
    //   cycle ACCUM[N-2]           →  psum_raw[N-1] = correct sum for col N-1
    //
    // The accumulator captures these one-cycle pulses and holds them until
    // output_valid is asserted.  It resets to zero whenever the controller
    // is idle (busy == 0), which happens between transactions.
    logic [PSUM_W-1:0] psum_raw   [N];   // direct sys_array output this cycle
    logic [PSUM_W-1:0] psum_accum [N];   // accumulated hold register

    always_ff @(posedge clk) begin
        if (!rst_n || !busy) begin
            for (int c = 0; c < N; c++)
                psum_accum[c] <= '0;
        end else if (!output_valid) begin
            // Accumulate while busy and result not yet valid
            for (int c = 0; c < N; c++)
                psum_accum[c] <= psum_accum[c] + psum_raw[c];
        end
        // When output_valid: hold (no update) until host reads and returns to IDLE
    end

    generate
        for (genvar gc = 0; gc < N; gc++) begin : gen_psum_out
            assign psum_out[gc] = psum_accum[gc];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Controller instance
    // -------------------------------------------------------------------------
    controller #(
        .N         (N),
        .PRECISION (PRECISION)
    ) u_controller (
        .clk          (clk),
        .rst_n        (rst_n),

        // Host handshake
        .start        (start),
        .busy         (busy),
        .output_valid (output_valid),
        .output_ready (output_ready),

        // Weight SRAM
        .w_addr       (w_addr),
        .w_data       (w_data),

        // Activation SRAM
        .a_col        (a_col),
        .a_data       (a_data),

        // sys_array control
        .weight_ld    (weight_ld),
        .weight_in    (weight_in),
        .act_in       (act_in)
    );

    // -------------------------------------------------------------------------
    // Systolic array instance
    // -------------------------------------------------------------------------
    sys_array #(
        .N         (N),
        .PRECISION (PRECISION)
    ) u_sys_array (
        .clk        (clk),
        .rst_n      (rst_n),

        // Weight load (driven by controller)
        .weight_ld  (weight_ld),
        .weight_in  (weight_in),

        // Activation stream (driven by controller)
        .act_in     (act_in),

        // Raw per-cycle output (feeds output accumulator above)
        .psum_out   (psum_raw)
    );

endmodule : minimac_top
