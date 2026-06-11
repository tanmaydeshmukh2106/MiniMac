# sys_array.sv — The NxN PE Grid

## What it does

Instantiates N×N copies of pe.sv and wires them together so that:
- Activations flow left → right across each row
- Partial sums accumulate top → bottom down each column

It is purely structural — no logic of its own, just wiring.

## The interconnect arrays

```systemverilog
logic [7:0]  act_h  [N][N+1];   // horizontal activation bus
logic [31:0] psum_v [N+1][N];   // vertical partial-sum bus
```

### act_h[r][c] — activation at column-entry c for row r

```
act_h[r][0]   = act_in[r]          (external input, row r's activation)
act_h[r][1]   = PE[r][0].act_out   (after passing through PE[r][0])
act_h[r][2]   = PE[r][1].act_out   (after passing through PE[r][1])
act_h[r][c]   = PE[r][c-1].act_out (general rule)
act_h[r][N]   = PE[r][N-1].act_out (exits the array, unused)
```

Why N+1 columns? So the last PE[r][N-1] has a valid act_out destination
(act_h[r][N]) without any special-casing. Clean boundary.

### psum_v[r][c] — partial sum at row-entry r for column c

```
psum_v[0][c]   = 0                  (top boundary, always zero)
psum_v[1][c]   = PE[0][c].psum_out  (result of row 0)
psum_v[2][c]   = PE[1][c].psum_out  (result of rows 0+1 accumulated)
psum_v[r][c]   = PE[r-1][c].psum_out
psum_v[N][c]   = PE[N-1][c].psum_out = FINAL result for column c
```

Why N+1 rows? Same reason — PE[0] needs a valid psum_in source (psum_v[0])
which is just wired to 0.

## Boundary conditions with generate/assign

```systemverilog
generate
    for (genvar gi = 0; gi < N; gi++) begin : gen_boundary
        assign act_h[gi][0]  = act_in[gi];   // wire act_in to left edge
        assign psum_v[0][gi] = '0;            // zero-feed at top
    end
endgenerate
```

Why not always_comb? ModelSim ASE crashes when you use a variable loop index
on a 2D unpacked array in an always_comb block. Using generate with genvar
makes the indices compile-time constants — no issue.

## PE instantiation

```systemverilog
generate
    for (genvar r = 0; r < N; r++) begin : gen_row
        for (genvar c = 0; c < N; c++) begin : gen_col
            pe u_pe (
                .act_in  (act_h[r][c]),      // comes from left
                .act_out (act_h[r][c+1]),    // goes right
                .psum_in (psum_v[r][c]),     // comes from above
                .psum_out(psum_v[r+1][c]),   // goes down
                .weight_ld(weight_ld[r][c]),
                .weight_in(weight_in[r][c]),
                ...
            );
        end
    end
endgenerate
```

For PE at row r, column c:
- It reads act_h[r][c] (the activation at column-entry c for its row)
- It writes act_h[r][c+1] (passes activation one step right)
- It reads psum_v[r][c] (partial sum from the PE above)
- It writes psum_v[r+1][c] (passes accumulated psum one step down)

## Output

```systemverilog
generate
    for (genvar gc = 0; gc < N; gc++) begin : gen_output
        assign psum_out[gc] = psum_v[N][gc];
    end
endgenerate
```

psum_v[N][gc] is the output of the bottom row PE in column gc.
This is the final accumulated sum for that column.

In minimac_top, this connects to psum_raw (not directly to psum_out)
because an output accumulator sits between them.

## Diagram of the full wiring for N=4

```
              act_in[0]   act_in[1]   act_in[2]   act_in[3]
                  │           │           │           │
           act_h[0][0] act_h[1][0] act_h[2][0] act_h[3][0]
                  │           │           │           │
psum_v[0][0]=0    │  psum_v[0][1]=0  ...
  │               │    │
  ▼               ▼    ▼
[PE[0][0]]──►[act_h[0][1]]   [PE[0][1]]──► ...
  │
psum_v[1][0]
  │
  ▼
[PE[1][0]]──►[act_h[1][1]]   ...
  │
psum_v[2][0]
  │
  ▼
[PE[2][0]]──►  ...
  │
psum_v[3][0]
  │
  ▼
[PE[3][0]]──►  ...
  │
psum_v[4][0]
  │
  ▼
psum_out[0]   psum_out[1]   psum_out[2]   psum_out[3]
```

## Why sys_array.sv has no logic of its own

It's intentionally just a structural wrapper. All the intelligence is in the controller
(which manages timing and sequencing) and in the PEs (which do the math). sys_array
just provides the physical interconnect. This is good hardware design practice:
separate structure from behavior.
