# controller.sv — The FSM

## Job

Sequences the systolic array through a fixed series of phases every transaction.
It never touches the math — it just controls timing, addressing, and handshaking.

## The five states

```
IDLE ──start──► LOAD_WEIGHTS ──done──► STREAM_ACT ──done──► ACCUMULATE ──done──► OUTPUT_VALID
  ▲                                                                                      │
  └─────────────────────────────output_ready─────────────────────────────────────────────┘
```

### IDLE
Sits here doing nothing until the host asserts `start` for one cycle.
All counters reset to zero. `busy = 0`.

### LOAD_WEIGHTS  (N×N = 16 cycles for N=4)

Loads each weight into its PE, one per cycle, row-major order.

Counter: `w_cnt` counts 0 → N²-1 (0 → 15 for N=4)

Address decode (for power-of-2 N only):
```systemverilog
w_row = w_cnt[LOG2_N +: LOG2_N];  // upper bits = row
w_col = w_cnt[0      +: LOG2_N];  // lower bits = col
```

For N=4, LOG2_N=2:
```
w_cnt=0  → w_row=0, w_col=0  → PE[0][0] gets weight
w_cnt=1  → w_row=0, w_col=1  → PE[0][1] gets weight
w_cnt=4  → w_row=1, w_col=0  → PE[1][0] gets weight
w_cnt=15 → w_row=3, w_col=3  → PE[3][3] gets weight
```

The controller drives:
```
w_addr = w_cnt               → SRAM outputs w_data = weight at that address
weight_ld[w_row][w_col] = 1  → target PE latches w_data into its weight_reg
weight_in[w_row][w_col] = w_data
```

All other PEs see weight_ld=0 so they don't latch anything.

Transition: when w_cnt == N²-1 (all weights loaded), go to STREAM_ACT.

### STREAM_ACT  (N = 4 cycles for N=4)

Streams activations through the array.

Counter: `a_cnt` counts 0 → N-1 (0 → 3 for N=4)

```systemverilog
a_col = a_cnt;    // tells the SRAM interface which column to serve
act_in[r] = a_data[r]  when state == STREAM_ACT, else 0
```

Because the interface uses `a_data[r] = a_mem[r] when a_col == r`:
- Cycle 0: a_col=0 → only row 0 gets act[0]
- Cycle 1: a_col=1 → only row 1 gets act[1]
- Cycle 2: a_col=2 → only row 2 gets act[2]
- Cycle 3: a_col=3 → only row 3 gets act[3]

This is the row-skewed activation delivery.

Transition: when a_cnt == N-1 (all rows streamed), go to ACCUMULATE.

### ACCUMULATE  (N = 4 cycles for N=4)

Waits for the pipeline to drain. No inputs driven — act_in = 0 during this phase.

Counter: `flush_cnt` counts 0 → FLUSH_CYCLES-1 = 0 → 3

```systemverilog
localparam int FLUSH_CYCLES = N;
```

Why N cycles? Column c's correct result arrives at psum_v[N][c] at cycle
N-1+c from start of STREAM_ACT. The last column (c=N-1) arrives at cycle
2N-2. ACCUMULATE starts at cycle N (after N STREAM_ACT cycles) and runs
for N cycles, ending at cycle 2N. So 2N-2 < 2N — all results captured. ✓

Transition: when flush_cnt == FLUSH_CYCLES-1, go to OUTPUT_VALID.

### OUTPUT_VALID

```systemverilog
output_valid = (state == OUTPUT_VALID);
busy         = (state != IDLE);
```

Stays here until the host asserts `output_ready` for one cycle (handshake).
The host reads psum_out during this window.
After handshake: go back to IDLE.

## Output signals at a glance

| Signal         | When asserted          | Meaning                          |
|----------------|------------------------|----------------------------------|
| busy           | any non-IDLE state     | DUT is working, don't start again |
| output_valid   | OUTPUT_VALID state     | psum_out holds valid result       |
| weight_ld[r][c]| LOAD_WEIGHTS, 1 PE/cycle | latch weight_in into this PE   |
| w_addr         | LOAD_WEIGHTS           | current weight SRAM address       |
| a_col          | STREAM_ACT             | which activation row to serve     |
| act_in[r]      | STREAM_ACT             | activation to drive into row r    |

## Counter width sizing

```systemverilog
logic [$clog2(N*N)-1:0]  w_cnt;       // for N=4: 4 bits (0..15)
logic [$clog2(N)-1:0]    a_cnt;       // for N=4: 2 bits (0..3)
logic [FLUSH_CNT_W-1:0]  flush_cnt;   // for N=4: 3 bits (0..4, needs +1)
```

$clog2(N) = ceiling(log2(N)). For N=4: $clog2(4)=2. For N=16: $clog2(16)=4.
The +1 in FLUSH_CNT_W = $clog2(FLUSH_CYCLES+1) handles the edge case where
FLUSH_CYCLES is a power of 2.

## Full state machine in code

```systemverilog
always_comb begin
    next_state = state;
    case (state)
        IDLE         : if (start)                          next_state = LOAD_WEIGHTS;
        LOAD_WEIGHTS : if (w_cnt == N*N - 1)              next_state = STREAM_ACT;
        STREAM_ACT   : if (a_cnt == N - 1)                next_state = ACCUMULATE;
        ACCUMULATE   : if (flush_cnt == FLUSH_CYCLES - 1) next_state = OUTPUT_VALID;
        OUTPUT_VALID : if (output_ready)                   next_state = IDLE;
    endcase
end
```

State register (synchronous):
```systemverilog
always_ff @(posedge clk)
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
```

Counter updates (each counter only increments in its own state, resets otherwise):
```systemverilog
always_ff @(posedge clk) begin
    case (state)
        LOAD_WEIGHTS : w_cnt     <= w_cnt + 1;
        STREAM_ACT   : a_cnt     <= a_cnt + 1;
        ACCUMULATE   : flush_cnt <= flush_cnt + 1;
        default      : begin w_cnt<=0; a_cnt<=0; flush_cnt<=0; end
    endcase
end
```

## Timeline for one full transaction (N=4)

```
Cycle:  0    1..15   16   17   18   19   20   21   22   23   24
State:  IDLE  LOAD_W  LW  SA0  SA1  SA2  SA3  AC0  AC1  AC2  AC3  OUTPUT_VALID
        ^start         ^weights   ^stream activations  ^flush      ^output_valid
        asserted       loaded     rows 0,1,2,3         pipeline    asserted
                                                       drains
```

(LW = LOAD_WEIGHTS last cycle, SA = STREAM_ACT, AC = ACCUMULATE)

Total: 1 (IDLE→LW) + 16 (LW) + 4 (SA) + 4 (AC) + hold = ~26 cycles per transaction.
