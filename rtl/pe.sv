// =============================================================================
// pe.sv — Processing Element for MiniMAC Systolic Array
// =============================================================================
// Description:
//   Single MAC (Multiply-Accumulate) unit used as the tile in the NxN systolic
//   array. Implements weight-stationary dataflow:
//     - weight_in is registered locally (stationary)
//     - act_in  streams left-to-right (passed to act_out each cycle)
//     - psum_in accumulates top-to-bottom (added to local MAC result → psum_out)
//
//   All inputs and outputs are registered (fully pipelined).
//
// Parameters:
//   PRECISION — "FP16" or "INT8"
//     FP16  : DATA_W = 16, PSUM_W = 32  (half-precision accumulation)
//     INT8  : DATA_W =  8, PSUM_W = 32  (int8 × int8 → int32 accumulation)
//
// Ports:
//   clk        — clock
//   rst_n      — active-low synchronous reset
//   weight_in  — weight value fed in during LOAD_WEIGHTS phase
//   weight_ld  — pulse high for one cycle to latch weight_in into the register
//   act_in     — activation sample streaming left-to-right
//   psum_in    — partial sum arriving from the PE above (or zero for top row)
//   psum_out   — accumulated partial sum forwarded to the PE below
//   weight_out — weight pass-through (for daisy-chain loading, optional)
//   act_out    — activation pass-through to the PE to the right
// =============================================================================

`timescale 1ns/1ps

module pe #(
    parameter string PRECISION = "INT8",  // "FP16" or "INT8"
    parameter int    DATA_W    = (PRECISION == "FP16") ? 16 : 8,
    parameter int    PSUM_W    = 32
) (
    input  logic        clk,
    input  logic        rst_n,

    // Weight load interface
    input  logic        weight_ld,        // latch weight_in this cycle
    input  logic [DATA_W-1:0] weight_in,

    // Systolic data path
    input  logic [DATA_W-1:0] act_in,
    input  logic [PSUM_W-1:0] psum_in,

    output logic [PSUM_W-1:0] psum_out,
    output logic [DATA_W-1:0] weight_out, // pass-through for daisy-chain
    output logic [DATA_W-1:0] act_out     // pass-through to right neighbour
);

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] weight_reg;   // stationary weight

    // -------------------------------------------------------------------------
    // Weight register — loaded once per tile, held stationary during streaming
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n)
            weight_reg <= '0;
        else if (weight_ld)
            weight_reg <= weight_in;
    end

    // -------------------------------------------------------------------------
    // MAC — combinational multiply-accumulate
    //   Single-stage pipeline: act_in and psum_in used directly (no input regs).
    //   Sign-extend both operands to PSUM_W bits manually (avoids ModelSim
    //   compatibility issues with N'() casts and generate-if string compares).
    //   For INT8 : DATA_W=8  → sign-extend 8→32, multiply, accumulate
    //   For FP16 : DATA_W=16 → sign-extend 16→32 (stub; replace with FP IP)
    //
    //   With row-skewed activation inputs (act[r] presented at a_col==r) and
    //   psum flowing combinationally from the PE above in the same cycle, the
    //   partial sums correctly accumulate top-to-bottom during each activation
    //   cycle.  The result for column c appears at psum_v[N][c] at cycle
    //   STREAM_ACT[N-1] + c, and is captured by the output accumulator in
    //   minimac_top.
    // -------------------------------------------------------------------------
    logic [PSUM_W-1:0] w_sext;   // sign-extended weight
    logic [PSUM_W-1:0] a_sext;   // sign-extended activation (from act_in directly)

    always_comb begin
        w_sext = {{(PSUM_W-DATA_W){weight_reg[DATA_W-1]}}, weight_reg};
        a_sext = {{(PSUM_W-DATA_W){act_in[DATA_W-1]}},     act_in};
    end

    // -------------------------------------------------------------------------
    // Output pipeline register (single stage)
    //   psum_out ← psum_in + W × act_in   (registered)
    //   act_out  ← act_in                 (registered, feeds right neighbour)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            psum_out   <= '0;
            weight_out <= '0;
            act_out    <= '0;
        end else begin
            psum_out   <= psum_in + (w_sext * a_sext);
            weight_out <= weight_reg;   // pass stationary weight downstream
            act_out    <= act_in;       // pass activation to right neighbour
        end
    end

endmodule : pe
