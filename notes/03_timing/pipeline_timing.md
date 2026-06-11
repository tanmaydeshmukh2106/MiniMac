# Pipeline Timing — The Most Important File

Read this slowly. This is what Bug 3 was about.
This is the hardest concept in the project and also the most impressive one to explain.

---

## Setup

N = 4. Weights already loaded. STREAM_ACT just started.
All weight registers have their correct values.
We only care about column 0 (the analysis is identical for all columns).

PE[r][0] holds weight W[r][0].
act[r] is the activation for row r.
We want: psum_out[0] = W[0][0]*act[0] + W[1][0]*act[1] + W[2][0]*act[2] + W[3][0]*act[3]

---

## The fixed design (how it actually works)

### Activation delivery (minimac_if.sv)

```
Cycle 0 (a_col=0): act_in[0]=act[0], act_in[1]=0, act_in[2]=0, act_in[3]=0
Cycle 1 (a_col=1): act_in[0]=0,      act_in[1]=act[1], act_in[2]=0, act_in[3]=0
Cycle 2 (a_col=2): act_in[0]=0,      act_in[1]=0, act_in[2]=act[2], act_in[3]=0
Cycle 3 (a_col=3): act_in[0]=0,      act_in[1]=0, act_in[2]=0, act_in[3]=act[3]
```

Row r gets its activation on cycle r. Staggered.

### The PE registers one output per clock

```
PE.psum_out ← psum_in + W * act_in   (registered at posedge)
```

psum_v[r+1][c] is wired directly to PE[r][c].psum_out.
psum_v[r][c] is wired directly to PE[r][c].psum_in.
These are combinational wires — no register between psum_out of one PE
and psum_in of the next. So the output of PE[r][c] is VISIBLE to PE[r+1][c]
in the NEXT cycle (after the posedge that produced it).

### Cycle-by-cycle trace for column 0

I'll write: "PE[r][0] sees (act_in, psum_in) → registers (psum_out) after posedge"

```
CYCLE 0 (a_col=0, a_cnt=0):
  PE[0][0]: act_in=act[0], psum_in=0
            → psum_out = 0 + W[0][0]*act[0]        registered at posedge 0
  PE[1][0]: act_in=0,      psum_in=PE[0][0].psum_out=0  (before posedge 0!)
            → psum_out = 0 + W[1][0]*0 = 0         registered at posedge 0
  PE[2][0]: similarly → psum_out = 0
  PE[3][0]: similarly → psum_out = 0

After posedge 0:
  psum_v[1][0] = W[0][0]*act[0]
  psum_v[2][0] = 0
  psum_v[3][0] = 0
  psum_v[4][0] = 0      ← psum_out[0] = 0 (wrong, not done yet)
```

```
CYCLE 1 (a_col=1, a_cnt=1):
  PE[0][0]: act_in=0, psum_in=0
            → psum_out = 0                          (clears to 0)
  PE[1][0]: act_in=act[1], psum_in=psum_v[1][0]=W[0][0]*act[0]  ← from posedge 0
            → psum_out = W[0][0]*act[0] + W[1][0]*act[1]   registered at posedge 1
  PE[2][0]: act_in=0, psum_in=psum_v[2][0]=0
            → psum_out = 0
  PE[3][0]: psum_out = 0

After posedge 1:
  psum_v[1][0] = 0                       (PE[0][0] cleared it)
  psum_v[2][0] = W[0][0]*act[0] + W[1][0]*act[1]
  psum_v[3][0] = 0
  psum_v[4][0] = 0      ← still 0
```

```
CYCLE 2 (a_col=2, a_cnt=2):
  PE[2][0]: act_in=act[2], psum_in=psum_v[2][0]=W[0][0]*act[0]+W[1][0]*act[1]
            → psum_out = sum_of_rows_0_1_2       registered at posedge 2
  (others: act_in=0 or psum from above is 0)

After posedge 2:
  psum_v[3][0] = W[0][0]*act[0] + W[1][0]*act[1] + W[2][0]*act[2]
  psum_v[4][0] = 0      ← still 0
```

```
CYCLE 3 (a_col=3, a_cnt=3) — LAST STREAM_ACT CYCLE:
  PE[3][0]: act_in=act[3], psum_in=psum_v[3][0]=sum_of_rows_0_1_2
            → psum_out = sum_of_all_4_rows        registered at posedge 3

After posedge 3:
  psum_v[4][0] = W[0][0]*act[0]+W[1][0]*act[1]+W[2][0]*act[2]+W[3][0]*act[3]
               = output[0]  ✓
```

**Column 0's correct result appears at psum_v[4][0] at cycle 4 (the cycle AFTER posedge 3).**
This is the last STREAM_ACT cycle → first ACCUMULATE cycle. The accumulator captures it. ✓

### Why column 1 arrives one cycle later

act[0] reaches PE[0][1] through act_h[0][1] = PE[0][0].act_out.
PE[0][0].act_out = act_in registered at posedge = act[0] registered at posedge 0.
So act[0] appears at PE[0][1].act_in at CYCLE 1 (one cycle after it appeared at PE[0][0]).

Same logic: act[r] reaches column c at cycle r+c.

So the entire computation for column 1 is shifted by 1 cycle relative to column 0.
Column 1's result appears at psum_v[4][1] at cycle 5.
Column 2 at cycle 6, column 3 at cycle 7.

```
Timeline (counting from STREAM_ACT start):
  Cycle 3: psum_v[4][0] = output[0]  ← captured during ACCUMULATE[0]
  Cycle 4: psum_v[4][1] = output[1]  ← captured during ACCUMULATE[1]
  Cycle 5: psum_v[4][2] = output[2]  ← captured during ACCUMULATE[2]
  Cycle 6: psum_v[4][3] = output[3]  ← captured during ACCUMULATE[3]
  Cycle 7: OUTPUT_VALID fires. All four values in psum_accum. ✓
```

---

## What went wrong in the original design

The original PE had INPUT registers:
```
act_reg  <= act_in;    // registers activation with 1-cycle delay
psum_reg <= psum_in;   // registers psum_in with 1-cycle delay
psum_out <= psum_reg + W * act_reg;   // uses DELAYED values
```

And the original interface delivered ALL activations at once:
```
a_data[r] = (a_col == '0) ? a_mem[r] : 0;  // all rows on cycle 0
```

### Tracing the original design (N=4, column 0)

```
CYCLE 0: a_col=0, all act_in[r] = act[r]
  PE[0][0]: act_reg=0,      psum_reg=0
            mac = 0 + W[0][0]*0 = 0
            psum_out = 0               registered at posedge 0
            act_reg ← act[0]           registered at posedge 0
  PE[1][0]: act_reg=0, psum_reg=0
            psum_out = 0
            act_reg ← act[1]

CYCLE 1: a_col=1, all act_in[r] = 0
  PE[0][0]: act_reg=act[0], psum_reg=0
            mac = 0 + W[0][0]*act[0]
            psum_out = W[0][0]*act[0]   registered at posedge 1
  PE[1][0]: act_reg=act[1], psum_reg=psum_in_at_cycle1
            psum_in at cycle 1 = PE[0][0].psum_out BEFORE posedge 1 = 0
            psum_reg ← 0               registered at posedge 1
            mac = 0 + W[1][0]*act[1]
            psum_out = W[1][0]*act[1]   registered at posedge 1

CYCLE 2:
  PE[1][0]: act_reg=0 (act_in was 0 at cycle 1)
            psum_reg = psum_in at cycle 1 = 0 (see above)
            mac = 0 + W[1][0]*0 = 0
  PE[2][0]: act_reg=act[2] (loaded at posedge 0), psum_reg=0
            psum_out = W[2][0]*act[2]

  At psum_v[4][0] = PE[3][0].psum_out = 0 still
```

**The problem is clear:** PE[1][0] computed W[1][0]*act[1] at posedge 1 and put it in psum_out.
But PE[0][0] only produced W[0][0]*act[0] ALSO at posedge 1.
psum_reg of PE[1][0] was latched DURING cycle 1, seeing psum_in = PE[0][0].psum_out BEFORE posedge 1 = 0.

They are always ONE CYCLE APART. act_reg and psum_reg can NEVER be the correct pair at the same time.
The products scatter across different cycles and never accumulate.

The simulation confirmed: outputs were random-looking partial values, never W.T @ act.

---

## Summary: why the fix works

| | Original | Fixed |
|---|---|---|
| PE stages | 2 (input + output reg) | 1 (output reg only) |
| psum_in used | previous-cycle value | current-cycle value (wire) |
| Activation delivery | all rows at cycle 0 | row r at cycle r |
| Accumulation | broken | correct |

With single-stage PE:
- psum_in is a WIRE — the current output of the PE above, updated each posedge
- act_in for row r arrives EXACTLY when psum from row r-1 is stable on the wire
- They combine in the same cycle ✓

The staggering ensures that when act[r] arrives at PE[r][0], the partial sum
from rows 0..r-1 is already sitting on psum_v[r][0] (output of PE[r-1][0]).
They register together into psum_v[r+1][0]. One cycle later that propagates to PE[r+1][0].
This "wave" of accumulation flows down each column naturally.
