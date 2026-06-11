# MiniMAC — AI Accelerator RTL + UVM Project

## What this project is
MiniMAC is a cycle-accurate, simulation-ready AI accelerator core built in SystemVerilog.
It implements a parameterized systolic array for matrix multiplication — the core primitive
of neural network inference (GEMM, Conv, Attention layers).

The project has three parts:
1. RTL design in SystemVerilog
2. Full UVM verification environment
3. Python golden reference model + test vector generator

## Owner
Tanmay — ECE student specializing in VLSI, targeting AI hardware acceleration roles.
Background: SystemVerilog, UVM, SVA, computer architecture, CUDA concepts, roofline analysis.

---

## Architecture decisions (locked in)

### Processing Element (pe.sv) — SINGLE-STAGE pipeline (important)
- Single MAC unit, weight-stationary dataflow
- Weight register: loaded once per transaction via weight_ld pulse, held stationary
- NO input pipeline registers for act_in or psum_in — both used directly in MAC
- Single output register: psum_out <= psum_in + W*act_in; act_out <= act_in
- This single-stage design is required for correct accumulation with row-skewed activation
- Ports: clk, rst_n, weight_in, weight_ld, act_in, psum_in, psum_out, weight_out, act_out

### Systolic Array (sys_array.sv)
- NxN grid of PE instances (N is a top-level parameter, default N=4)
- Dataflow: Weight-Stationary (weights preloaded into PEs, activations stream left-to-right, partial sums flow top-to-bottom)
- act_h[N][N+1] and psum_v[N+1][N] for boundary-free interconnect
- Boundary conditions via generate/assign (genvar) — NOT always_comb — for ModelSim compat
- psum_out[gc] = psum_v[N][gc] via generate/assign
- Output feeds psum_raw in minimac_top (NOT psum_out directly — see accumulator below)

### Controller (controller.sv)
- FSM: IDLE → LOAD_WEIGHTS → STREAM_ACT → ACCUMULATE → OUTPUT_VALID
- LOAD_WEIGHTS: N*N cycles, row-major weight addressing via w_cnt bit-select
- STREAM_ACT: N cycles, a_col increments 0→N-1 each cycle
- ACCUMULATE: FLUSH_CYCLES = N cycles (flush_cnt 0→N-1)
- OUTPUT_VALID: held until output_ready handshake, then back to IDLE
- Ready/valid handshake; flat SRAM-style memory interface (not AXI)
- busy = (state != IDLE); output_valid = (state == OUTPUT_VALID)

### Top level (minimac_top.sv) — HAS OUTPUT ACCUMULATOR (important)
- Instantiates controller + sys_array
- sys_array output goes to psum_raw[N], NOT directly to psum_out[N]
- OUTPUT ACCUMULATOR: psum_accum[N] registers that sum psum_raw each cycle
  - Reset to 0 when !rst_n OR !busy (between transactions)
  - Accumulate (+=) when busy && !output_valid (during LOAD_WEIGHTS, STREAM_ACT, ACCUMULATE)
  - Hold when output_valid (result stable for host to read)
  - psum_out[c] = psum_accum[c] via generate/assign
- This accumulator is required because each column c's correct result appears as a
  1-cycle pulse at psum_raw[c] at a different time (col 0 at end of STREAM_ACT, col c at
  ACCUMULATE cycle c-1). The accumulator catches each pulse and holds everything.

### Activation SRAM interface (minimac_if.sv) — ROW-SKEWED (important)
- a_data[r] = a_mem[r] ONLY when a_col == r, else 0
- NOT a_col == '0 for all rows simultaneously (that was the bug)
- Row-skewed delivery: act[r] arrives at PE row r on controller cycle r of STREAM_ACT
- This staggers activations so each row's activation aligns with the partial sum arriving
  from the PE above — enabling correct W.T @ act accumulation

---

## How the correct computation works (pipeline timing)

Formula: psum_out[c] = sum_r( W[r][c] * act[r] ) = W.T @ act

With single-stage PE + row-skewed activation (a_col == r means act[r] presented at cycle r):
- Cycle 0 of STREAM_ACT: act[0] → PE[0][c] computes W[0][c]*act[0], registers at posedge 0
- Cycle 1: act[1] → PE[1][c], psum_in = W[0][c]*act[0] already on wire → computes sum of rows 0+1
- Cycle 2: act[2] → PE[2][c], psum_in = sum rows 0+1 → sum of rows 0+1+2
- Cycle N-1: act[N-1] → PE[N-1][c], psum_in = sum of rows 0..N-2 → full sum
- Full sum appears at psum_v[N][c] at cycle N-1+c (c cycles of horizontal propagation)
- Column 0 result: at cycle N-1 (last STREAM_ACT cycle)
- Column c result: at ACCUMULATE cycle c-1
- All captured by output accumulator, held at psum_accum until OUTPUT_VALID

FLUSH_CYCLES = N is correct: last column (c=N-1) result arrives at ACCUMULATE cycle N-2,
which is within the N-cycle ACCUMULATE window.

---

## UVM Testbench (COMPLETE AND PASSING)

### File: uvm/minimac_pkg.sv (single package with all UVM classes)
- minimac_seq_item: rand weights[N][N] + act[N], NO uvm_object_utils (Riviera-PRO conflict)
- minimac_transaction: weights + act + actual + expected, NO uvm_object_utils
- minimac_scoreboard: uvm_component_utils OK; reads from mailbox; compares actual vs expected
- minimac_driver: loads vif.w_mem and vif.a_mem, pulses start, waits output_valid, handshakes
- minimac_monitor: on output_valid, reads vif.w_mem/a_mem, captures psum_out, computes
  expected = W.T @ act with sign extension (logic signed [31:0]), puts to mailbox
- minimac_agent: driver + monitor + sequencer
- minimac_env: creates shared mailbox #(minimac_transaction), sets in config_db with "*"
- minimac_sequence: N_TESTS randomized items, NO uvm_object_utils, uses new() not type_id
- minimac_test: creates env, runs sequence of 10 transactions

### File: uvm/minimac_if.sv
- Contains SRAM model: w_mem[N*N] and a_mem[N], written by driver
- w_data = w_mem[w_addr] (combinational)
- a_data[r] = (a_col == ($clog2(N))'(r)) ? a_mem[r] : 8'h0 (row-skewed)

### File: uvm/tb_top.sv
- Instantiates clock, minimac_if, minimac_top DUT, sets vif in config_db, calls run_test

### EDA Playground setup
- ALL 7 files concatenated into single testbench.sv (left side)
  Order: pe.sv, sys_array.sv, controller.sv, minimac_top.sv, minimac_if.sv, minimac_pkg.sv, tb_top.sv
- design.sv (right side): empty
- UVM/OVM dropdown: UVM 1.1d (required — without it uvm_pkg undefined)
- Run Options: +UVM_TESTNAME=minimac_test work.tb_top
- Simulator: Riviera-PRO 2025.04

### Critical EDA Playground quirks discovered
- uvm_object_utils on seq_item / transaction / sequence causes "Invalid virtual method override"
  error in Riviera-PRO 2025.04 (ships UVM 1800.2-2020 internally but dropdown says 1.1d)
  FIX: remove uvm_object_utils from those 3 classes; use new() instead of type_id::create()
- uvm_component_utils on component classes is fine — no conflict
- Left tabs compile before right tabs; all files must be in left testbench.sv
- Mailbox-based scoreboard avoids all analysis port / TLM FIFO infrastructure conflicts

### Result
PASS: 40  FAIL: 0  (10 transactions × 4 outputs each)
UVM_INFO: 67  UVM_WARNING: 0  UVM_ERROR: 0  UVM_FATAL: 0

---

## Python golden model (COMPLETE)

### golden/matmul_ref.py
- minimac_ref(W, act): returns W.astype(int32).T @ act.astype(int32)
- clamp_int8(x): clips to [-128, 127]
- Self-test matches tb_simple.sv smoke test: W[0][0]=5, act[0]=3 → out[0]=15 ✓

### golden/gen_vectors.py
- Generates N test vectors: 6 corner cases + (n_tests-6) random
- Corner cases: smoke, all-zeros, identity W, max positive, max neg/pos, alternating signs
- Writes weights_XXX.hex, act_XXX.hex, expected_XXX.hex to golden/vectors/
- Usage: python gen_vectors.py --n_tests 20 --seed 42

---

## Folder structure (actual)
MiniMAC/
├── rtl/
│   ├── pe.sv           ← single-stage MAC (no input regs)
│   ├── sys_array.sv    ← NxN PE grid with generate/assign boundaries
│   ├── controller.sv   ← FSM, FLUSH_CYCLES=N
│   └── minimac_top.sv  ← controller + sys_array + output accumulator
├── uvm/
│   ├── minimac_if.sv   ← interface + SRAM model (row-skewed a_data)
│   ├── minimac_pkg.sv  ← all UVM classes in one package
│   └── tb_top.sv       ← testbench top module
├── golden/
│   ├── matmul_ref.py
│   ├── gen_vectors.py
│   └── vectors/        ← generated .hex test vectors
└── sim/
    └── tb_simple.sv    ← plain SV smoke test (no UVM)

---

## Current status
- [x] Folder structure created
- [x] pe.sv — single-stage MAC, weight-stationary, INT8/FP16 parameterized
- [x] sys_array.sv — NxN PE grid, generate/assign boundaries, compatible with ModelSim+Riviera
- [x] controller.sv — FSM, FLUSH_CYCLES=N, flat SRAM interface
- [x] minimac_top.sv — controller + sys_array + output accumulator register
- [x] sim/tb_simple.sv — plain SV smoke test, psum_out[0]=15 verified in ModelSim
- [x] UVM environment — minimac_pkg.sv + minimac_if.sv + tb_top.sv, mailbox-based scoreboard
- [x] Python golden model — matmul_ref.py + gen_vectors.py, 20 vectors generated
- [x] Full UVM simulation — PASS:40 FAIL:0 on EDA Playground (Riviera-PRO 2025.04)
- [ ] Theory walkthrough — pe.sv, sys_array, controller, top, UVM, Python (next session)
- [ ] README.md for GitHub
- [ ] Waveform screenshots for portfolio

---

## Key bugs found and fixed (important for interviews)

### Bug 1: FLUSH_CYCLES too large
- Original: FLUSH_CYCLES = 3*N. output_valid fired 8 cycles after psum was already valid.
- Fix: FLUSH_CYCLES = N. Result is ready after N cycles of STREAM_ACT + N cycles of ACCUMULATE.

### Bug 2: sys_array always_comb with 2D unpacked array (ModelSim ASE)
- Original: always_comb with variable loop index on 2D unpacked array crashed ModelSim.
- Fix: generate/assign with genvar (compile-time constants) for boundary assignments.

### Bug 3: Systolic array pipeline timing — root cause of PASS:0 FAIL:40
- Original 2-stage PE (act_reg + psum_reg input registers) + simultaneous activation
  (all rows presented when a_col==0): each PE computed its product before the partial
  sum from the PE above arrived. Products were never accumulated — 40/40 mismatches.
- Fix A — pe.sv: remove input registers. Use act_in and psum_in directly in MAC.
  Now psum_in is already on the wire when act_in arrives, so they combine in one cycle.
- Fix B — minimac_if.sv: change a_data[r] condition from (a_col=='0) to (a_col==r).
  Row-skewed delivery: act[r] arrives at PE row r at controller cycle r of STREAM_ACT.
  This aligns each row's activation with the partial sum from the row above.
- Fix C — minimac_top.sv: add output accumulator (psum_accum) because with single-stage
  PE, each column's correct result exists for only 1 cycle. The accumulator sums these
  one-cycle pulses and holds the result until output_valid.

### Bug 4: EDA Playground UVM — "Invalid virtual method override" (3 errors)
- Root cause: Riviera-PRO 2025.04 uses UVM 1800.2-2020 internally; uvm_object_utils macro
  from the 1.1d dropdown generates virtual function signatures that conflict with 2020 base class.
- Exactly 3 classes triggered it: minimac_seq_item, minimac_transaction, minimac_sequence.
- Fix: remove uvm_object_utils from those 3; use new() instead of type_id::create().

---

## How to continue in any new session
1. Read this CLAUDE.md first — it has complete architecture, all bugs/fixes, current status
2. Read the relevant .sv file if you need exact port details
3. The next unchecked items are: theory walkthrough, README, waveform screenshots
4. For theory walkthrough: go file by file — pe.sv → sys_array → controller → minimac_top
   → minimac_if → minimac_pkg → tb_top → Python golden model
   Cover: signal widths, pipeline timing, what each signal does, why each design choice was made
