// =============================================================================
// controller.sv — FSM Controller for MiniMAC Systolic Array
// =============================================================================
// Description:
//   Sequences the systolic array through five phases:
//
//     IDLE         — wait for start pulse from host
//     LOAD_WEIGHTS — iterate through all N×N PEs row-major (N² cycles),
//                    presenting each weight from the flat weight SRAM and
//                    pulsing weight_ld to latch it into the PE
//     STREAM_ACT   — drive N activation columns (one per cycle, 0…N-1) into
//                    act_in[N] from the N-banked activation SRAM
//     ACCUMULATE   — wait FLUSH_CYCLES for the pipeline to drain completely
//                    (horizontal propagation + vertical psum chain)
//     OUTPUT_VALID — assert output_valid; hold until output_ready handshake
//
// Memory interfaces (flat, combinational-read style for simulation):
//
//   Weight SRAM   : NxN locations, row-major addressing
//                     w_addr = row*N + col  (range 0 … N²-1)
//                   Assumed 0-cycle read latency. For synchronous SRAM, add
//                   one pipeline register on w_data before feeding weight_in.
//
//   Activation SRAM: N banks, one per array row; each bank holds N values.
//                     a_col = column index streamed each cycle (0 … N-1)
//                   a_data[N] returns one activation per row simultaneously.
//
// Pipeline flush budget:
//   After the last activation cycle, worst-case latency to psum_out[N-1]:
//     horizontal propagation : N-1 cycles  (act reaches column N-1)
//     vertical accumulation  : 2*N cycles  (2 register stages per PE × N rows)
//   Total = 3*N-1.  FLUSH_CYCLES = 3*N adds one cycle of margin.
//
// Parameters:
//   N         — array dimension; must match sys_array N (default 4)
//   PRECISION — "INT8" or "FP16"  → DATA_W = 8 or 16
//
// NOTE: Row/column decode from w_cnt uses bit-select and is exact only for
//       power-of-two N (N=4, 8, 16).  Replace with / and % for arbitrary N
//       at the cost of synthesising dividers.
// =============================================================================

`timescale 1ns/1ps

module controller #(
    parameter int    N         = 4,
    parameter string PRECISION = "INT8",
    parameter int    DATA_W    = (PRECISION == "FP16") ? 16 : 8
) (
    input  logic clk,
    input  logic rst_n,

    // ── Host handshake ────────────────────────────────────────────────────
    input  logic        start,          // pulse high 1 cycle to begin; ignored while busy
    output logic        busy,           // high throughout any non-IDLE state
    output logic        output_valid,   // high when psum_out[N] holds valid result
    input  logic        output_ready,   // handshake: accept result and return to IDLE

    // ── Weight SRAM (row-major flat, combinational read) ──────────────────
    output logic [$clog2(N*N)-1:0]  w_addr,      // address 0 … N²-1
    input  logic [DATA_W-1:0]        w_data,      // weight read data

    // ── Activation SRAM (N-banked, one activation per row per cycle) ──────
    output logic [$clog2(N)-1:0]    a_col,       // column index 0 … N-1
    input  logic [DATA_W-1:0]        a_data [N],  // one activation per row

    // ── sys_array control outputs ─────────────────────────────────────────
    output logic                     weight_ld  [N][N],
    output logic [DATA_W-1:0]        weight_in  [N][N],
    output logic [DATA_W-1:0]        act_in     [N]
);

    // -------------------------------------------------------------------------
    // Pipeline flush budget
    // -------------------------------------------------------------------------
    localparam int FLUSH_CYCLES = N;
    localparam int FLUSH_CNT_W  = $clog2(FLUSH_CYCLES + 1);

    // -------------------------------------------------------------------------
    // Log2 of N (exact for power-of-two N)
    // -------------------------------------------------------------------------
    localparam int LOG2_N = $clog2(N);

    // -------------------------------------------------------------------------
    // FSM state encoding
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE         = 3'd0,
        LOAD_WEIGHTS = 3'd1,
        STREAM_ACT   = 3'd2,
        ACCUMULATE   = 3'd3,
        OUTPUT_VALID = 3'd4
    } state_t;

    state_t state, next_state;

    // -------------------------------------------------------------------------
    // Counters
    // -------------------------------------------------------------------------
    logic [$clog2(N*N)-1:0]  w_cnt;      // weight PE index  0 … N²-1
    logic [$clog2(N)-1:0]    a_cnt;      // activation column 0 … N-1
    logic [FLUSH_CNT_W-1:0]  flush_cnt;  // pipeline-drain counter

    // -------------------------------------------------------------------------
    // Row / column decode from w_cnt
    //   Upper LOG2_N bits → row,  lower LOG2_N bits → col
    //   Equivalent to row = w_cnt/N, col = w_cnt%N for power-of-two N.
    // -------------------------------------------------------------------------
    logic [LOG2_N-1:0] w_row, w_col;
    assign w_row = w_cnt[LOG2_N +: LOG2_N];   // bits [2*LOG2_N-1 : LOG2_N]
    assign w_col = w_cnt[0      +: LOG2_N];   // bits [LOG2_N-1   : 0      ]

    // -------------------------------------------------------------------------
    // State register
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    // -------------------------------------------------------------------------
    // Next-state logic
    // -------------------------------------------------------------------------
    always_comb begin
        next_state = state;
        case (state)
            IDLE         : if (start)                              next_state = LOAD_WEIGHTS;
            LOAD_WEIGHTS : if (w_cnt == N*N - 1)                  next_state = STREAM_ACT;
            STREAM_ACT   : if (a_cnt == N - 1)                    next_state = ACCUMULATE;
            ACCUMULATE   : if (flush_cnt == FLUSH_CYCLES - 1)     next_state = OUTPUT_VALID;
            OUTPUT_VALID : if (output_ready)                       next_state = IDLE;
            default      :                                         next_state = IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Counter updates
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_cnt     <= '0;
            a_cnt     <= '0;
            flush_cnt <= '0;
        end else begin
            case (state)
                LOAD_WEIGHTS : w_cnt     <= w_cnt + 1;
                STREAM_ACT   : a_cnt     <= a_cnt + 1;
                ACCUMULATE   : flush_cnt <= flush_cnt + 1;
                default      : begin
                    w_cnt     <= '0;
                    a_cnt     <= '0;
                    flush_cnt <= '0;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Combinational outputs: busy, output_valid
    // -------------------------------------------------------------------------
    assign busy         = (state != IDLE);
    assign output_valid = (state == OUTPUT_VALID);

    // -------------------------------------------------------------------------
    // SRAM addresses
    // -------------------------------------------------------------------------
    assign w_addr = w_cnt;
    assign a_col  = a_cnt;

    // -------------------------------------------------------------------------
    // weight_ld / weight_in — one-hot PE select during LOAD_WEIGHTS
    // -------------------------------------------------------------------------
    always_comb begin
        for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++) begin
                weight_ld[r][c] = 1'b0;
                weight_in[r][c] = '0;
            end
        if (state == LOAD_WEIGHTS) begin
            weight_ld[w_row][w_col] = 1'b1;
            weight_in[w_row][w_col] = w_data;
        end
    end

    // -------------------------------------------------------------------------
    // act_in — drive from activation SRAM during STREAM_ACT; zero otherwise
    // -------------------------------------------------------------------------
    always_comb begin
        for (int r = 0; r < N; r++)
            act_in[r] = (state == STREAM_ACT) ? a_data[r] : '0;
    end

endmodule : controller
