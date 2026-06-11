# UVM Architecture

## What UVM gives you vs a plain testbench

### Plain SV testbench (sim/tb_simple.sv)
```
initial begin
    // manually set weights
    // manually pulse start
    // manually wait
    // manually check psum_out
end
```
Works but:
- You have to hardcode every test case
- No separation between stimulus generation and checking
- To add more tests you copy-paste blocks of code
- If you change the DUT interface you rewrite the whole testbench

### UVM testbench (uvm/)
- Stimulus is randomized automatically (rand keyword + constraint solver)
- Driver, monitor, scoreboard are separate classes with defined responsibilities
- You can swap in a different sequence (different stimulus pattern) without touching
  the driver or scoreboard
- The infrastructure is reusable across different DUTs
- Industry standard — every chip company uses UVM

## The UVM class hierarchy in this project

```
minimac_test  (uvm_test)
  └── minimac_env  (uvm_env)
        ├── minimac_agent  (uvm_agent)
        │     ├── minimac_driver    (uvm_driver)
        │     ├── minimac_monitor   (uvm_monitor)
        │     └── uvm_sequencer     (built-in)
        │           └── minimac_sequence → minimac_seq_item
        └── minimac_scoreboard  (uvm_component)

Shared: mailbox #(minimac_transaction)  (plain SV, not UVM TLM)
```

## How data flows through the testbench

```
[minimac_sequence]
  generates randomized seq_items
        │
        ▼ (seq_item_port / seq_item_export)
[uvm_sequencer]
  queues items
        │
        ▼ (get_next_item / item_done)
[minimac_driver]
  writes to vif.w_mem, vif.a_mem
  pulses vif.start
  waits for vif.output_valid
  pulses vif.output_ready
        │
        │ (DUT runs)
        │
        ▼
[minimac_monitor]
  watches vif.output_valid
  reads vif.psum_out (actual)
  reads vif.w_mem, vif.a_mem (to compute expected)
  creates minimac_transaction
  puts to mailbox
        │
        ▼
[minimac_scoreboard]
  gets from mailbox
  compares actual vs expected
  prints PASS or FAIL
```

## The virtual interface

The DUT lives in the simulator. UVM classes are SystemVerilog objects (classes).
They can't directly access module signals. The bridge is a virtual interface:

```systemverilog
// In tb_top.sv: the real interface instance
minimac_if #(.N(N)) mif (.clk(clk));

// Register it so anyone can get it
uvm_config_db #(virtual minimac_if #(N))::set(null, "*", "vif", mif);

// In driver/monitor build_phase: get the handle
uvm_config_db #(virtual minimac_if #(N))::get(this, "", "vif", vif);
```

Now `vif` in the driver/monitor is a handle to the real `mif` interface in tb_top.
Anything you write to `vif.w_mem` actually changes `mif.w_mem` in the simulation.

## The mailbox (why not analysis ports)

Standard UVM uses `uvm_analysis_port` + `uvm_tlm_analysis_fifo` to connect
monitor to scoreboard. This requires `uvm_analysis_imp_decl` macros and specific
virtual function signatures.

On Riviera-PRO 2025.04, those macros conflict with the internal UVM 1800.2-2020
library and cause "Invalid virtual method override" errors — even for the infrastructure
classes, not just the user classes.

Solution: use a plain SystemVerilog `mailbox`:
```systemverilog
mailbox #(minimac_transaction) result_mbx;
```

- In minimac_env.build_phase: `result_mbx = new(0);` (unbounded mailbox)
- Set in config_db so both monitor and scoreboard can get it
- Monitor: `result_mbx.put(txn);`
- Scoreboard: `result_mbx.get(txn);` (blocking — waits until one is available)

Same functionality, zero infrastructure, no macro conflicts.

## UVM phases

UVM has a fixed phase execution order. The important ones:

```
build_phase    → create child components, get config_db values
connect_phase  → connect ports (driver seq_item_port → sequencer seq_item_export)
run_phase      → actual simulation runs here (tasks, not functions)
report_phase   → print summary
```

build_phase runs top-down (test builds env, env builds agent+scoreboard, agent builds driver+monitor).
connect_phase runs bottom-up.
run_phase: all components run concurrently (each has its own process).

The test controls simulation time via objections:
```systemverilog
phase.raise_objection(this);  // simulation won't end
// ... run the sequence ...
phase.drop_objection(this);   // simulation can end
```

## What run_test does

```systemverilog
run_test("minimac_test");  // in tb_top.sv
```

This is the UVM entry point. It:
1. Creates a minimac_test instance
2. Runs all phases in order
3. Calls $finish when all objections are dropped
