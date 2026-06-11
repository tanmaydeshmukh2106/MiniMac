// =============================================================================
// sys_array.sv — NxN Systolic Array for MiniMAC
// =============================================================================
// Description:
//   Instantiates an NxN grid of PE tiles and wires them for weight-stationary
//   dataflow:
//
//     - Activations stream LEFT → RIGHT across each row
//       act_in[row] enters column 0; each PE passes act_out to its right neighbour
//
//     - Partial sums accumulate TOP → BOTTOM down each column
//       Top row receives psum_in = 0; each PE passes psum_out downward
//       Bottom row psum_out = final dot-product result for that column
//
//     - Weights are STATIONARY — loaded once before streaming begins
//       Each PE has its own weight_in and weight_ld signal
//       Controller pulses weight_ld[row][col] to latch the correct weight
//
//   After N streaming cycles (one activation row per cycle), each column's
//   bottom psum_out holds one element of the output matrix row.
//
// Parameters:
//   N         — array dimension (default 4 → 4×4 array)
//   PRECISION — passed through to every PE ("INT8" or "FP16")
//
// Port widths derived from PRECISION:
//   DATA_W = 8  (INT8) or 16 (FP16)
//   PSUM_W = 32 always
//
// Ports:
//   clk               — clock
//   rst_n             — active-low synchronous reset
//
//   weight_ld  [N][N] — per-PE weight load enable (pulse high to latch)
//   weight_in  [N][N] — per-PE weight data
//
//   act_in     [N]    — activation input for each row (column 0 entry point)
//   psum_out   [N]    — final accumulated output for each column (bottom row)
// =============================================================================

`timescale 1ns/1ps

module sys_array #(
    parameter int    N         = 4,
    parameter string PRECISION = "INT8",
    parameter int    DATA_W    = (PRECISION == "FP16") ? 16 : 8,
    parameter int    PSUM_W    = 32
) (
    input  logic clk,
    input  logic rst_n,

    // Weight load interface — one signal per PE
    input  logic                    weight_ld  [N][N],
    input  logic [DATA_W-1:0]       weight_in  [N][N],

    // Activation inputs — one per row, enters at column 0
    input  logic [DATA_W-1:0]       act_in     [N],

    // Final output — one per column, exits from bottom row
    output logic [PSUM_W-1:0]       psum_out   [N]
);

    // -------------------------------------------------------------------------
    // Internal interconnect wires
    //
    //   act_h[row][col]  — horizontal activation bus
    //                      act_h[row][0]   = act_in[row]  (external input)
    //                      act_h[row][j+1] = act_out of PE[row][j]
    //
    //   psum_v[row][col] — vertical partial-sum bus
    //                      psum_v[0][col]  = 0            (zero feed at top)
    //                      psum_v[i+1][col]= psum_out of PE[i][col]
    //                      psum_out[col]   = psum_v[N][col]
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] act_h  [N][N+1];   // N rows, N+1 horizontal taps
    logic [PSUM_W-1:0] psum_v [N+1][N];   // N+1 vertical taps, N columns

    // -------------------------------------------------------------------------
    // Tie external activation inputs to column-0 entry points
    // Tie top-row psum inputs to zero
    // Using generate/assign with genvar (constant indices) for ModelSim compat.
    // -------------------------------------------------------------------------
    generate
        for (genvar gi = 0; gi < N; gi++) begin : gen_boundary
            assign act_h[gi][0]  = act_in[gi];
            assign psum_v[0][gi] = '0;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // PE grid instantiation
    // -------------------------------------------------------------------------
    generate
        for (genvar r = 0; r < N; r++) begin : gen_row
            for (genvar c = 0; c < N; c++) begin : gen_col

                pe #(
                    .PRECISION (PRECISION)
                ) u_pe (
                    .clk        (clk),
                    .rst_n      (rst_n),

                    // Weight load
                    .weight_ld  (weight_ld [r][c]),
                    .weight_in  (weight_in [r][c]),

                    // Horizontal activation chain (left → right)
                    .act_in     (act_h  [r][c]),
                    .act_out    (act_h  [r][c+1]),

                    // Vertical psum chain (top → bottom)
                    .psum_in    (psum_v [r][c]),
                    .psum_out   (psum_v [r+1][c]),

                    // weight_out unused at array level (daisy-chain optional)
                    .weight_out ()
                );

            end : gen_col
        end : gen_row
    endgenerate

    // -------------------------------------------------------------------------
    // Connect bottom-row psum outputs to array output ports
    // -------------------------------------------------------------------------
    generate
        for (genvar gc = 0; gc < N; gc++) begin : gen_output
            assign psum_out[gc] = psum_v[N][gc];
        end
    endgenerate

endmodule : sys_array
