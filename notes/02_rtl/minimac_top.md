# minimac_top.sv — Top-Level Wrapper

## What it contains

1. Controller instance
2. sys_array instance
3. Output accumulator (the critical addition)
4. Wire connections between all three

## Why an output accumulator is needed

With the single-stage PE and row-skewed activation, each column c's correct
final result appears at sys_array's psum_out (called psum_raw here) for
exactly ONE clock cycle:

```
Column 0: correct result at cycle N-1   (last STREAM_ACT cycle)
Column 1: correct result at cycle N     (first ACCUMULATE cycle)
Column 2: correct result at cycle N+1   (second ACCUMULATE cycle)
Column 3: correct result at cycle N+2   (third ACCUMULATE cycle)
```

After that one cycle, psum_raw[c] goes back to 0 because:
- act_in is 0 (STREAM_ACT is over)
- psum_in for the next cycle is 0 (the previous accumulated value already left)

So if you just wire psum_raw directly to psum_out, the host would have to sample
EACH output at a DIFFERENT cycle. Impossible with a single output_valid signal.

The accumulator solves this:

```systemverilog
always_ff @(posedge clk) begin
    if (!rst_n || !busy) begin
        // Reset between transactions (whenever not busy)
        for (int c = 0; c < N; c++)
            psum_accum[c] <= '0;

    end else if (!output_valid) begin
        // Sum up every cycle while working
        // During LOAD_WEIGHTS: psum_raw=0 (no activations), adds 0, no effect
        // During STREAM_ACT:   psum_raw[0] gets its pulse at last cycle, captured
        // During ACCUMULATE:   psum_raw[1..3] get their pulses, each captured
        for (int c = 0; c < N; c++)
            psum_accum[c] <= psum_accum[c] + psum_raw[c];

    end
    // During OUTPUT_VALID: no update → holds value for host to read
end
```

```
psum_raw[0]:  0 0 0 ... 0 105  0   0   0  →  accumulated: 105
psum_raw[1]:  0 0 0 ... 0  0  31   0   0  →  accumulated:  31
psum_raw[2]:  0 0 0 ... 0  0   0 146   0  →  accumulated: 146
psum_raw[3]:  0 0 0 ... 0  0   0   0  31  →  accumulated:  31
              ←LOAD_W──►  ←STREAM─► ←ACCUM→
```

At OUTPUT_VALID: psum_accum = [105, 31, 146, 31]. All four correct. ✓

## Why reset when !busy, not when rst_n only

If you reset only on rst_n, then between two back-to-back transactions the
accumulator still holds the previous result. The next transaction would ACCUMULATE
ON TOP OF that old value — wrong.

`!busy` means IDLE state. Every time the controller returns to IDLE, the accumulator
resets to 0. Next transaction starts fresh.

## Output wiring

```systemverilog
generate
    for (genvar gc = 0; gc < N; gc++) begin : gen_psum_out
        assign psum_out[gc] = psum_accum[gc];
    end
endgenerate
```

generate/assign instead of a direct assign psum_out = psum_accum because psum_out
is a packed array output port and some simulators are fussy about port array
assignments without explicit per-element wiring.

## Full picture

```
                          minimac_top
  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  start ──►┌─────────────┐  weight_ld[N][N]             │
  │  busy  ◄──│             │  weight_in[N][N]  ┌─────────┐│
  │  ov    ◄──│ controller  │──────────────────►│         ││──► psum_raw
  │  or    ──►│             │  act_in[N]         │sys_array││
  │           │             │──────────────────►│         ││
  │           └─────────────┘                   └─────────┘│
  │                │busy  │ov                        │      │
  │                ▼      ▼                     psum_raw    │
  │           ┌──────────────────────────────────────────┐  │
  │           │  output accumulator                      │  │
  │           │  if !busy: reset                         │  │
  │           │  elif !ov: accumulate                    │  │
  │           │  else:     hold                          │  │
  │           └──────────────────────────────────────────┘  │
  │                              │psum_accum                 │
  │                              ▼                           │
  │                          psum_out[N]                     │
  └─────────────────────────────────────────────────────────┘
```

## Signal naming in this file

| Internal name | Connected to         | Meaning                          |
|---------------|----------------------|----------------------------------|
| psum_raw      | sys_array.psum_out   | raw per-cycle array output       |
| psum_accum    | (register)           | accumulated hold register        |
| psum_out      | top-level port       | what the host reads              |
| busy          | controller.busy      | also used to gate accumulator    |
| output_valid  | controller.ov        | also used to stop accumulating   |
