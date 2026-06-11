# pe.sv — Processing Element

## What it is

The single tile that gets replicated N×N times in sys_array.sv.
Each PE holds one weight value permanently (weight-stationary) and
performs one MAC (multiply-accumulate) per clock cycle.

## Ports

```
Inputs:
  clk, rst_n          standard clock and active-low reset

  weight_ld           pulse HIGH for one cycle to latch weight_in
  weight_in [7:0]     the weight value to store (int8)

  act_in    [7:0]     activation arriving from the left  (int8)
  psum_in   [31:0]    partial sum arriving from above    (int32)

Outputs:
  psum_out  [31:0]    accumulated result, goes downward  (int32)
  act_out   [7:0]     activation passed rightward        (int8)
  weight_out [7:0]    weight pass-through (unused at array level)
```

## The weight register

```systemverilog
always_ff @(posedge clk) begin
    if (!rst_n)         weight_reg <= '0;
    else if (weight_ld) weight_reg <= weight_in;
end
```

weight_reg is loaded ONCE per transaction during LOAD_WEIGHTS.
It never changes during streaming. This is what "weight-stationary" means.
The controller pulses weight_ld for exactly one cycle per PE, one PE at a time.

## The MAC (multiply-accumulate)

```systemverilog
// sign-extend int8 to int32 before multiplying
w_sext = {{24{weight_reg[7]}}, weight_reg};   // replicate bit 7 (sign bit) 24 times
a_sext = {{24{act_in[7]}},     act_in};

// single output register
always_ff @(posedge clk) begin
    psum_out <= psum_in + (w_sext * a_sext);
    act_out  <= act_in;
end
```

### Why sign extension?

int8 can be negative. -1 in int8 = 8'hFF = 255 unsigned.
If you multiply 8'hFF * 8'hFF as unsigned: 255*255 = 65025. Wrong.
Sign-extended to int32: -1 * -1 = +1. Correct.

The sign extension: `{{24{weight_reg[7]}}, weight_reg}`
- weight_reg[7] is the MSB (sign bit)
- {24{weight_reg[7]}} replicates it 24 times → fills bits [31:8]
- then append the original 8 bits → bits [7:0]
Result: a 32-bit signed value representing the same number as the 8-bit input.

### Why a single output register (no input registers)?

The original design had:
```systemverilog
// ORIGINAL — WRONG
act_reg  <= act_in;   // input register for activation
psum_reg <= psum_in;  // input register for psum
mac = psum_reg + W * act_reg;  // uses REGISTERED values
psum_out <= mac;
```

The problem: act_reg and psum_reg are from the PREVIOUS cycle.
When act[r] arrives at PE[r][c] and psum from PE[r-1][c] also arrives
at the same cycle, the PE sees last cycle's psum (which is 0) not the
freshly computed one. The MAC is wrong. See 03_timing/ for the full trace.

The fix: remove act_reg and psum_reg. Use act_in and psum_in directly:
```systemverilog
// FIXED — CORRECT
psum_out <= psum_in + (w_sext * a_sext);  // current-cycle inputs
```

Now psum_in is the wire directly connected to psum_v[r][c] in sys_array.
When PE[r-1][c] produces its result, it appears on that wire immediately
(combinationally). PE[r][c] sees it in the SAME cycle and combines it
with act_in. All correct.

## What act_out does

```systemverilog
act_out <= act_in;
```

This is just a 1-cycle register delay that passes the activation rightward.
act_h[r][c+1] = PE[r][c].act_out
So act[r] reaches PE[r][1] one cycle after PE[r][0], PE[r][2] two cycles after, etc.
This is the horizontal propagation delay that staggers activations across columns.

## Signal widths summary

| Signal     | Width | Type   | Why                                      |
|------------|-------|--------|------------------------------------------|
| weight_in  | 8     | int8   | INT8 precision                           |
| weight_reg | 8     | int8   | same                                     |
| act_in     | 8     | int8   | INT8 precision                           |
| act_out    | 8     | int8   | pass-through, same width                 |
| psum_in    | 32    | int32  | accumulates up to N products             |
| psum_out   | 32    | int32  | same                                     |
| w_sext     | 32    | int32  | sign-extended before multiply            |
| a_sext     | 32    | int32  | sign-extended before multiply            |

## One-line summary for interviews

"Each PE holds one INT8 weight permanently. Every clock cycle it computes
psum_out = psum_in + weight × activation and passes the activation rightward.
Single register stage — no input pipeline registers — so the partial sum from
the PE above is available combinationally in the same cycle."
