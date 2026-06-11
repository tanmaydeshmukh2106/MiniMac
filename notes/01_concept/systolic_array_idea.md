# The Systolic Array Idea

## Why not just use a loop?

A simple for-loop matmul in software:
```
for r in range(N):
    for c in range(N):
        output[c] += W[r][c] * act[r]
```

This runs one multiply-accumulate (MAC) at a time. N² MACs total, sequentially.
For N=4: 16 MACs. For N=256 (typical TPU): 65,536 MACs.

A systolic array runs ALL N² MACs simultaneously in a pipeline.
For N=4: 16 PEs all working in parallel, result ready in ~2N cycles instead of N² cycles.

## The grid structure

```
         act[0]  act[1]  act[2]  act[3]
           │       │       │       │
           ▼       ▼       ▼       ▼
        ┌──────┬──────┬──────┬──────┐
   0 ──►│PE[0,0]│PE[0,1]│PE[0,2]│PE[0,3]│──►
        ├──────┼──────┼──────┼──────┤
   0 ──►│PE[1,0]│PE[1,1]│PE[1,2]│PE[1,3]│──►
        ├──────┼──────┼──────┼──────┤
   0 ──►│PE[2,0]│PE[2,1]│PE[2,2]│PE[2,3]│──►
        ├──────┼──────┼──────┼──────┤
   0 ──►│PE[3,0]│PE[3,1]│PE[3,2]│PE[3,3]│──►
        └──────┴──────┴──────┴──────┘
           │       │       │       │
           ▼       ▼       ▼       ▼
        out[0]  out[1]  out[2]  out[3]
```

Arrows on the left: psum flowing top→bottom (starts as 0)
Arrows on top: activations flowing left→right (row r's act enters from top at row r)
Arrows at bottom: final accumulated output per column

Wait — in MiniMAC activations enter from the LEFT of each row, not the top.
The diagram above shows the conceptual data flow. Here's the actual wiring:

```
act[0] ──► [PE[0,0]] ──► [PE[0,1]] ──► [PE[0,2]] ──► [PE[0,3]] ──►
             │               │               │               │
             ▼               ▼               ▼               ▼
act[1] ──► [PE[1,0]] ──► [PE[1,1]] ──► [PE[1,2]] ──► [PE[1,3]] ──►
             │               │               │               │
             ▼               ▼               ▼               ▼
act[2] ──► [PE[2,0]] ──► [PE[2,1]] ──► [PE[2,2]] ──► [PE[2,3]] ──►
             │               │               │               │
             ▼               ▼               ▼               ▼
act[3] ──► [PE[3,0]] ──► [PE[3,1]] ──► [PE[3,2]] ──► [PE[3,3]] ──►
             │               │               │               │
             ▼               ▼               ▼               ▼
          out[0]          out[1]          out[2]          out[3]
```

Horizontal (─►): activation passes left to right through each PE in a row
Vertical (▼): partial sum passes top to bottom through each PE in a column

## What each PE does

PE at row r, column c holds weight W[r][c] (loaded before computation starts).

Each clock cycle:
```
psum_out = psum_in + W[r][c] * act_in
act_out  = act_in   (pass activation to the right)
```

So:
- It multiplies its stationary weight by whatever activation is coming from the left
- It adds the product to whatever partial sum is coming from above
- It passes the activation rightward to the next PE
- It passes the accumulated psum downward to the next PE

## Why output[c] = sum_r W[r][c]*act[r]

Column c has PEs: PE[0][c], PE[1][c], PE[2][c], PE[3][c]
Each holds W[0][c], W[1][c], W[2][c], W[3][c] respectively.

When act[0] flows through row 0 and hits PE[0][c]:
  psum = 0 + W[0][c]*act[0]

That psum flows down to PE[1][c]. When act[1] flows through row 1 and hits PE[1][c]:
  psum = W[0][c]*act[0] + W[1][c]*act[1]

...and so on down the column. At the bottom:
  psum = W[0][c]*act[0] + W[1][c]*act[1] + W[2][c]*act[2] + W[3][c]*act[3]
       = output[c]  ✓

## Key insight: why it's fast

In a CPU doing this with a loop: 16 MACs, one at a time = 16 cycles minimum.

In the systolic array: all 16 PEs are doing MACs simultaneously every cycle.
The result for the full matrix-vector multiply is ready in ~2N cycles = 8 cycles for N=4.

This is why every AI chip uses some form of this. Google's TPU v1 was a 256×256
systolic array — 65,536 PEs all running in parallel.

## The staggering requirement (critical — relates to Bug 3)

For the PEs in a column to correctly accumulate, the activations must arrive
STAGGERED by row:
- act[0] arrives at row 0 at cycle 0
- act[1] arrives at row 1 at cycle 1
- act[2] arrives at row 2 at cycle 2
- act[3] arrives at row 3 at cycle 3

Why? Because the partial sum from PE[0][c] takes 1 cycle to propagate to PE[1][c].
If act[1] arrives at PE[1][c] at the same time as act[0] (cycle 0), then
PE[1][c] sees psum_in = 0 (PE[0][c] hasn't computed yet). The sum is wrong.

If act[1] arrives 1 cycle later (cycle 1), PE[1][c] sees psum_in = W[0][c]*act[0]
(just produced by PE[0][c]). The sum is correct.

This staggering is implemented in minimac_if.sv:
  a_data[r] = act[r] only when a_col == r

The controller increments a_col each cycle (0,1,2,3) so row r naturally
gets its activation on cycle r of STREAM_ACT.
