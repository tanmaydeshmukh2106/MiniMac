# MiniMAC

Parameterized weight-stationary systolic array for INT8 matrix-vector multiply.
Verified end-to-end with a UVM testbench on Riviera-PRO.

Target operation: `psum_out[c] = Σ_r W[r][c] * act[r]` — equivalently `W.T @ act`
where W is N×N int8, act is N×1 int8, output is N×1 int32.

---

## Repo layout

```
rtl/
  pe.sv            single-stage MAC tile (weight-stationary)
  sys_array.sv     N×N PE grid, act flows L→R, psum flows T→B
  controller.sv    FSM: IDLE→LOAD_WEIGHTS→STREAM_ACT→ACCUMULATE→OUTPUT_VALID
  minimac_top.sv   top wrapper + output accumulator register

uvm/
  minimac_if.sv    SV interface, SRAM model, row-skewed activation delivery
  minimac_pkg.sv   all UVM classes (seq_item, driver, monitor, scoreboard, env, test)
  tb_top.sv        testbench top, clock gen, DUT instantiation, run_test

sim/
  tb_simple.sv     directed SV smoke test (no UVM)
  run.do           ModelSim script

golden/
  matmul_ref.py    NumPy reference: W.astype(int32).T @ act.astype(int32)
  gen_vectors.py   generates .hex test vectors (corner cases + random)
  vectors/         20 pre-generated test cases
```

---

## RTL notes

**pe.sv** — single output register, no input registers.
`psum_out <= psum_in + signed'(weight_reg) * signed'(act_in)`
`act_out  <= act_in`

Input registers were removed after finding they broke accumulation (see bugs below).
With no input registers, psum_in from the PE above is available in the same cycle
as act_in, so the product and incoming partial sum combine correctly.

**sys_array.sv** — boundary conditions use `generate/assign` with `genvar`,
not `always_comb`, to avoid a ModelSim ASE crash on 2D unpacked array indexing.

**controller.sv** — weight address decoded from flat counter via bit-select:
`w_row = w_cnt[LOG2_N +: LOG2_N]`, `w_col = w_cnt[0 +: LOG2_N]`.
Exact only for power-of-2 N. `FLUSH_CYCLES = N`.

**minimac_top.sv** — output accumulator on top of sys_array:
```
if (!busy)          psum_accum <= 0
else if (!ov)       psum_accum <= psum_accum + psum_raw
// hold when output_valid
```
Required because with a single-stage PE and row-skewed activation, column c's
correct result appears at `psum_raw[c]` for exactly one cycle (cycle N-1+c from
start of STREAM_ACT). The accumulator captures each pulse and holds all N results
until the host reads them.

**minimac_if.sv** — activation SRAM response is row-skewed:
```systemverilog
a_data[r] = (a_col == ($clog2(N))'(r)) ? a_mem[r] : 8'h0;
```
Controller increments `a_col` 0→N-1 during STREAM_ACT, so act[r] is naturally
delivered to row r on cycle r. This aligns each row's activation with the partial
sum propagating down from the PE above.

---

## Simulation

### Smoke test — ModelSim ASE
```
cd sim
vsim -do run.do
```
Checks: W[0][0]=5, act[0]=3 → psum_out[0]=15.

### UVM — EDA Playground (Riviera-PRO 2025.04)

Concatenate all 7 files into one `testbench.sv` in this order:
```
pe.sv  sys_array.sv  controller.sv  minimac_top.sv
minimac_if.sv  minimac_pkg.sv  tb_top.sv
```
Leave `design.sv` empty. Set UVM dropdown to **UVM 1.1d**.
Run options: `+UVM_TESTNAME=minimac_test work.tb_top`

Result:
```
PASS: 40   FAIL: 0
UVM_INFO: 67   UVM_WARNING: 0   UVM_ERROR: 0   UVM_FATAL: 0
```
10 randomised INT8 transactions × 4 outputs each.

### Python golden model
```bash
python golden/matmul_ref.py      # runs self-test, prints PASS
python golden/gen_vectors.py     # writes 20 .hex vectors to golden/vectors/
```

---

## Bugs fixed

**1. FLUSH_CYCLES = 3N → N**
Original comment in controller.sv calculated flush budget as 3N-1 cycles
(N-1 horizontal + 2N vertical). This was based on the 2-stage PE latency,
which no longer applies after the pipeline fix below. With single-stage PEs
and row-skewed inputs, column c's result arrives at cycle N-1+c.
Last column (c=N-1) arrives at cycle 2N-2, within a 2N-cycle window.
FLUSH_CYCLES=N is correct.

**2. ModelSim ASE: 2D unpacked array in always_comb**
```
// broken — ModelSim fatal on variable index into 2D unpacked
always_comb
    for (int i = 0; i < N; i++) psum_v[0][i] = '0;

// fix
generate
    for (genvar gi = 0; gi < N; gi++)
        assign psum_v[0][gi] = '0;
endgenerate
```

**3. Pipeline timing — root cause of PASS:0 FAIL:40**

Original pe.sv had two input registers:
```
act_reg  <= act_in;
psum_reg <= psum_in;
mac = psum_reg + W * act_reg;
psum_out <= mac;
```

Original minimac_if.sv delivered all rows simultaneously:
```
a_data[r] = (a_col == '0) ? a_mem[r] : 8'h0;  // all rows at once
```

With this setup: at cycle 0 of STREAM_ACT, all act[r] are presented.
PE[0][0] latches act[0] into act_reg; at cycle 1 mac=W[0][0]*act[0] →
psum_out=W[0][0]*act[0] at cycle 2. Meanwhile PE[1][0] also latched act[1]
at cycle 0, computed W[1][0]*act[1] at cycle 1, output at cycle 2.
psum_in for PE[1][0] at cycle 1 = PE[0][0].psum_out at cycle 1 = 0
(PE[0][0] hasn't produced its result yet). The two products never accumulate.

Fix: remove act_reg and psum_reg from pe.sv so the MAC sees current-cycle
inputs. Change activation delivery to row-skewed (a_col==r). Now:
- Cycle 0: act[0] → PE[0][c], psum_in=0, mac=W[0][c]*act[0], registered at posedge 0
- Cycle 1: act[1] → PE[1][c], psum_in=W[0][c]*act[0] (on wire from PE[0][c]),
  mac=W[0][c]*act[0]+W[1][c]*act[1], registered at posedge 1
- ...
- Cycle N-1: full sum at bottom of column c

Each row's activation arrives exactly when the partial sum from the row above
is ready on the wire. Single register stage, no stall, no bubbles.

**4. EDA Playground: uvm_object_utils conflict**
Riviera-PRO 2025.04 links UVM 1800.2-2020 internally. The `uvm_object_utils`
macro from the 1.1d dropdown generates `get_type_name()` and `create()` with
signatures that conflict with the 2020 base class virtual methods.
Affects only classes derived from `uvm_object` (not `uvm_component`).
Fix: remove `uvm_object_utils` from `minimac_seq_item`, `minimac_transaction`,
`minimac_sequence`. Use `new()` instead of `type_id::create()`.

---

## Parameters

| Parameter   | Default  | Notes                                   |
|-------------|----------|-----------------------------------------|
| `N`         | 4        | Array dimension. Power-of-2 only.       |
| `PRECISION` | `"INT8"` | `"INT8"` → DATA_W=8. `"FP16"` → stub.  |

---

## Tools

| Tool | Version | Use |
|------|---------|-----|
| ModelSim ASE | 10.5b | RTL smoke test |
| Riviera-PRO | 2025.04 | UVM simulation |
| EDA Playground | — | cloud sim environment |
| Python | 3.10 | golden model + vector gen |
| NumPy | — | reference matmul |
