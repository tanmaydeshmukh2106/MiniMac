# All Bugs — Root Cause, Symptom, Fix

---

## Bug 1 — FLUSH_CYCLES = 3N instead of N

### Where
controller.sv, localparam

### Original code
```systemverilog
localparam int FLUSH_CYCLES = 3 * N;
```

### Symptom
In ModelSim, the waveform showed psum_out[0] = 15 at 295ns but output_valid
only went high at 385ns — 8 cycles (= 2×N cycles) too late.
The correct value was sitting in psum_out the whole time but the host couldn't
read it because output_valid wasn't asserted yet.

### Root cause
The comment in controller.sv calculated flush budget as:
- N-1 cycles for horizontal activation propagation
- 2×N cycles for vertical psum accumulation (2 pipeline stages per PE)
- Total: 3N-1, rounded up to 3N

This calculation was based on the 2-stage PE (with input registers).
After the PE was fixed to single-stage, the correct flush budget is N.

Derivation for single-stage PE with row-skewed activation:
- Column c's result appears at psum_v[N][c] at cycle N-1+c from STREAM_ACT start
- Last column (c=N-1): appears at cycle 2N-2
- ACCUMULATE starts at cycle N, runs for FLUSH_CYCLES
- Need ACCUMULATE to cover cycle 2N-2, which is ACCUMULATE cycle N-2
- FLUSH_CYCLES = N covers cycles 0..N-1 of ACCUMULATE, includes N-2. ✓

### Fix
```systemverilog
localparam int FLUSH_CYCLES = N;
```

---

## Bug 2 — ModelSim crash: 2D unpacked array in always_comb

### Where
sys_array.sv, boundary condition assignments

### Original code
```systemverilog
always_comb begin
    for (int i = 0; i < N; i++) begin
        act_h[i][0]  = act_in[i];   // variable index on 2D unpacked
        psum_v[0][i] = '0;
    end
end
```

### Symptom
ModelSim ASE fatal error:
```
** Fatal: (vsim-3601) Illegal array assignment to type '$[0:3]' from type 'reg[31:0]$[0:3]'
```

### Root cause
ModelSim ASE (the free version) cannot handle a variable (non-constant) index into
a 2D unpacked array inside an always_comb block. It's a tool limitation — the SV
standard allows it but ModelSim ASE's elaborator chokes on it.

### Fix
Replace always_comb + variable index with generate + assign + genvar (compile-time constant):

```systemverilog
generate
    for (genvar gi = 0; gi < N; gi++) begin : gen_boundary
        assign act_h[gi][0]  = act_in[gi];   // gi is a compile-time constant
        assign psum_v[0][gi] = '0;
    end
endgenerate

generate
    for (genvar gc = 0; gc < N; gc++) begin : gen_output
        assign psum_out[gc] = psum_v[N][gc];
    end
endgenerate
```

genvar is a compile-time loop variable. Each iteration generates a separate
`assign` statement with a literal constant index. No runtime variable indexing.

---

## Bug 3 — Systolic array pipeline timing (root cause of PASS:0 FAIL:40)

### Where
pe.sv (2-stage pipeline), minimac_if.sv (simultaneous activation), minimac_top.sv (no accumulator)

### Symptom
UVM ran 10 transactions, 40/40 outputs failed. Example:
```
psum_out[0] FAIL  got=6758  exp=3176
psum_out[1] FAIL  got=6270  exp=5370
```
The "got" values were not random noise — they were partial sums, meaning the MAC
was computing but never accumulating correctly. No pattern between got and exp.

### Root cause (the detailed version)

**Part A: 2-stage PE**

Original pe.sv:
```systemverilog
always_ff @(posedge clk) begin
    act_reg  <= act_in;    // STAGE 1: register activation
    psum_reg <= psum_in;   // STAGE 1: register partial sum in
end
// MAC uses REGISTERED values (from previous cycle)
mac_result = psum_reg + W * act_reg;
always_ff @(posedge clk) begin
    psum_out <= mac_result;  // STAGE 2: register MAC result
end
```

With 2 register stages: PE input appears at output 2 cycles later.

**Part B: Simultaneous activation delivery**

Original minimac_if.sv:
```systemverilog
a_data[r] = (a_col == '0) ? a_mem[r] : 8'h0;  // ALL rows at a_col=0
```

All N rows of act arrive simultaneously at cycle 0 of STREAM_ACT.

**Why this breaks accumulation:**

At cycle 0: PE[0][0] latches act[0] into act_reg.
At cycle 1: PE[0][0] computes W[0][0]*act[0], produces psum_out = W[0][0]*act[0].

At cycle 0: PE[1][0] ALSO latches act[1] into act_reg.
           psum_reg ← psum_in at cycle 0 = PE[0][0].psum_out at cycle 0 = 0
At cycle 1: PE[1][0] computes 0 + W[1][0]*act[1] = W[1][0]*act[1]
           produces its own separate product — NOT summed with PE[0][0]'s result

PE[1][0]'s psum_in was PE[0][0]'s output BEFORE posedge 1. But PE[0][0]
only produced W[0][0]*act[0] AT posedge 1. They miss each other by exactly 1 cycle
and can never combine. Every PE computes in isolation. No accumulation happens.

The products appeared scattered at psum_v[N][c] at various cycles but never summed.
The output accumulator in minimac_top summed THESE PARTIAL VALUES → wrong results.

### The three-part fix

**Fix A — pe.sv: single-stage pipeline**

Remove act_reg and psum_reg. Use act_in and psum_in directly:

```systemverilog
// FIXED pe.sv
always_ff @(posedge clk) begin
    psum_out <= psum_in + (w_sext * a_sext);  // psum_in and act_in used directly
    act_out  <= act_in;
end
```

Now psum_in is a combinational wire. When PE[r-1][c] produces W*act at posedge T,
that value is immediately visible on psum_v[r][c] during cycle T+1.
PE[r][c] can use it in the SAME cycle it receives act[r]. No 1-cycle miss.

**Fix B — minimac_if.sv: row-skewed activation**

```systemverilog
// FIXED minimac_if.sv
a_data[r] = (a_col == ($clog2(N))'(r)) ? a_mem[r] : 8'h0;
```

Now row r's activation is delivered only when a_col == r.
Controller cycles a_col 0,1,2,3 during STREAM_ACT.
So act[0] arrives at cycle 0, act[1] at cycle 1, etc.

With single-stage PE: when act[r] arrives at PE[r][0] at cycle r,
PE[r-1][0] produced its result at posedge r-1 → it's on psum_v[r][0] during cycle r.
They combine. Correct accumulation. ✓

**Fix C — minimac_top.sv: output accumulator**

With single-stage PE + skewed activation, each column c's correct result appears
at psum_raw[c] for exactly ONE cycle (cycle N-1+c from STREAM_ACT start).

Without the accumulator: that value disappears after one cycle, gone before OUTPUT_VALID.

The accumulator:
```systemverilog
if (!busy)       psum_accum <= 0;        // reset between transactions
else if (!ov)    psum_accum += psum_raw; // capture each column's pulse
// else hold
```

Each column's one-cycle pulse gets added in, held in psum_accum until OUTPUT_VALID.

### Why the smoke test (W[0][0]=5, act[0]=3) passed even with the bugs

With only PE[0][0] active and all other weights = 0:
- Only one PE contributes → no inter-PE accumulation needed
- The broken accumulation path was irrelevant — there was nothing to accumulate

The smoke test was necessary but not sufficient. Only the full random matrix test
(where all PEs contribute) exposed the pipeline timing bug.

---

## Bug 4 — EDA Playground: "Invalid virtual method override"

### Where
minimac_pkg.sv — uvm_object_utils on three classes

### Original code
```systemverilog
class minimac_seq_item extends uvm_sequence_item;
    `uvm_object_utils(minimac_seq_item)   // ← causes error
    ...
endclass

class minimac_transaction extends uvm_object;
    `uvm_object_utils(minimac_transaction)   // ← causes error
    ...
endclass

class minimac_sequence extends uvm_sequence #(minimac_seq_item);
    `uvm_object_utils(minimac_sequence)   // ← causes error
    ...
endclass
```

### Symptom
```
Error: (vlog-2110) Invalid virtual method override.
  Base method 'create' has different return type
Error: (vlog-2110) Invalid virtual method override.
  Base method 'get_type_name' has different return type
```
Three errors, one per class that used uvm_object_utils.

### Root cause
EDA Playground's UVM/OVM dropdown says "UVM 1.1d" but Riviera-PRO 2025.04
actually links against UVM 1800.2-2020 internally.

The `uvm_object_utils` macro from UVM 1.1d generates virtual functions
`create()` and `get_type_name()` with specific return type signatures.
But the UVM 1800.2-2020 base class (uvm_object) defines those same functions
with DIFFERENT signatures.

When the macro tries to override the base class functions, SV says "the override
has a different return type than the base method" → compilation error.

Exactly the three classes that extend uvm_object (not uvm_component) are affected.
uvm_component_utils works fine because uvm_component's base signatures happen to match.

### Fix
Remove uvm_object_utils from the three affected classes.
Switch from type_id::create() to plain new():

```systemverilog
class minimac_seq_item extends uvm_sequence_item;
    // NO uvm_object_utils
    // rand fields ...
    function new(string name = "minimac_seq_item");
        super.new(name);
    endfunction
endclass

// In sequence body():
minimac_seq_item item = new("item");   // not type_id::create()

// In monitor:
minimac_transaction txn = new("txn");  // not type_id::create()
```

What you lose: factory override capability (can't substitute a different type
via the factory at runtime). For this project that's not needed, so the fix
is clean with zero functional impact.

uvm_component_utils on driver, monitor, scoreboard, agent, env, test: keep as-is.
Those classes derive from uvm_component, not uvm_object, and have no conflict.
