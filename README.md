# MiniMAC

Parameterized weight-stationary systolic array for INT8 matrix-vector multiply.
Verified end-to-end with a UVM testbench on Riviera-PRO.

Target operation: `psum_out[c] = Σ_r W[r][c] * act[r]` — equivalently `W.T @ act`
where W is N×N int8, act is N×1 int8, output is N×1 int32, T is for transpose matrix.

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


## Simulation

### Smoke test — ModelSim ASE
```
cd sim
vsim -do run.do
```
Checks: W[0][0]=5, act[0]=3 → psum_out[0]=15.

### UVM — EDA Playground (Riviera-PRO 2025.04)

Concatenated all 7 files into one `testbench.sv` in this order:
```
pe.sv ; sys_array.sv ; controller.sv ; minimac_top.sv ;
minimac_if.sv ; minimac_pkg.sv ; tb_top.sv
```
Settings: 
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

1. FLUSH_CYCLES = 3N → N
Original comment in controller.sv calculated flush budget as 3N-1 cycles
(N-1 horizontal + 2N vertical). This was based on the 2-stage PE latency,
which no longer applies after the pipeline fix below. With single-stage PEs
and row-skewed inputs, column c's result arrives at cycle N-1+c.
Last column (c=N-1) arrives at cycle 2N-2, within a 2N-cycle window.
FLUSH_CYCLES=N is correct.

2. ModelSim ASE: 2D unpacked array in always_comb
```
// error : ModelSim fatal on variable index into 2D unpacked
always_comb
    for (int i = 0; i < N; i++) psum_v[0][i] = '0;

// fixed by: . Instead of one always_comb block with a for loop, we get N separate assign statements generated before simulation even starts. 
ecvaluated at compilation.
generate
    for (genvar gi = 0; gi < N; gi++)
        assign psum_v[0][gi] = '0;
endgenerate
```

3. Pipeline timing — root cause of PASS:0 FAIL:40

This one took a while to figure out. UVM was giving PASS:0 FAIL:40 and the outputs looked pretty valid.
Root cause: the original PE had input registers on both act_in and psum_in. With all activations delivered simultaneously at cycle 0, PE[1][0] latched psum_in at the same cycle PE[0][0] was computing its result ; so it captured 0 instead of W[0][0]*act[0]. They were always exactly one cycle apart and could never really combine. Every PE computed its product in isolation and nothing was actually accumulated.
Fix was three parts. Removed the input registers from pe.sv so psum_in is a direct wire; the output of the PE above is immediately visible in the same cycle. Changed activation delivery from simultaneous to row-skewed: row r gets its activation only when a_col==r, so act[1] arrives at PE[1][0] exactly when W[0][0]*act[0] is sitting on the wire from PE[0][0]. Changed the accumulator in minimac_top to sum psum_raw each cycle because with single-stage PEs each column's result only exists for one clock cycle at a different time. The accumulator catches each pulse and holds everything until output_valid.
After all three changes, we finally got PASS:40 FAIL:0.

4. EDA Playground: uvm_object_utils conflict
Riviera-PRO 2025.04 links UVM 1800.2-2020 internally. The `uvm_object_utils`
macro from the 1.1d dropdown generates `get_type_name()` and `create()` with
signatures that conflict with the 2020 base class virtual methods.
Affects only classes derived from `uvm_object` (not `uvm_component`).
We fixed this by removing `uvm_object_utils` from `minimac_seq_item`, `minimac_transaction`,
`minimac_sequence`. Use `new()` instead of `type_id::create()`.

---
