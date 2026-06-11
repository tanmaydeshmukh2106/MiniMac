# UVM Classes — Each One Explained

## minimac_seq_item

```systemverilog
class minimac_seq_item extends uvm_sequence_item;
    rand byte weights [N][N];   // N×N int8 matrix
    rand byte act     [N];      // N int8 values
    // NO uvm_object_utils — Riviera-PRO conflict (see bugs)
endclass
```

This is the "packet" of stimulus. The `rand` keyword means SystemVerilog's
constraint solver randomizes weights and act automatically.

`byte` in SV = signed 8-bit = int8. Range: -128 to 127. Correct for INT8.

Why NO uvm_object_utils? See Bug 4 in 06_bugs/. Short answer: it conflicts
with Riviera-PRO's internal UVM version. Removing it means you can't use
type_id::create() but everything else still works.

---

## minimac_transaction

```systemverilog
class minimac_transaction extends uvm_object;
    logic [7:0]  weights [N][N];   // captured from interface
    logic [7:0]  act     [N];      // captured from interface
    logic [31:0] actual  [N];      // what DUT produced
    logic [31:0] expected[N];      // what monitor computed
endclass
```

This is NOT the stimulus — it's the RESULT. The monitor creates one of these
after each transaction completes, fills in actual (from DUT) and expected
(computed from weights/act), and sends it to the scoreboard.

Why logic not byte? Scoreboard uses === comparison which handles X/Z correctly.
byte would silently treat X as 0.

---

## minimac_driver

```systemverilog
task run_phase(uvm_phase phase);
    // 1. Initialize interface signals
    vif.rst_n = 0; vif.start = 0; vif.output_ready = 0;
    repeat(4) @(posedge vif.clk);   // hold reset for 4 cycles
    vif.rst_n = 1;
    @(posedge vif.clk);
    
    forever begin
        seq_item_port.get_next_item(req);  // blocking: waits for next item
        drive_txn(req);
        seq_item_port.item_done();         // tells sequencer we're done
    end
endtask
```

### drive_txn — the actual driving

```systemverilog
task drive_txn(minimac_seq_item item);
    // Load weight SRAM model (the interface's backing arrays)
    for (int r = 0; r < N; r++)
        for (int c = 0; c < N; c++)
            vif.w_mem[r*N + c] = item.weights[r][c];   // row-major flat

    // Load activation SRAM model
    for (int r = 0; r < N; r++)
        vif.a_mem[r] = item.act[r];

    // Pulse start
    @(posedge vif.clk);
    vif.start = 1;
    @(posedge vif.clk);
    vif.start = 0;

    // Wait for output_valid (timeout after 500 cycles)
    do @(posedge vif.clk); while (!vif.output_valid);

    // Handshake
    vif.output_ready = 1;
    @(posedge vif.clk);
    vif.output_ready = 0;

    // Wait for DUT to return to IDLE
    do @(posedge vif.clk); while (vif.busy);
    @(posedge vif.clk);  // one extra cycle of margin
endtask
```

Key point: the driver writes to `vif.w_mem` and `vif.a_mem` (the SRAM model arrays
inside the interface), not to w_data/a_data directly. The interface's always_comb block
then responds to w_addr/a_col from the DUT and returns the right data. So the driver
just loads the data once; the DUT reads it through the SRAM interface organically.

---

## minimac_monitor

```systemverilog
task run_phase(uvm_phase phase);
    forever begin
        @(posedge vif.clk);
        if (vif.output_valid) begin
            minimac_transaction txn = new("txn");

            // Capture weights and act (from SRAM model the driver loaded)
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    txn.weights[r][c] = vif.w_mem[r*N + c];
            for (int r = 0; r < N; r++)
                txn.act[r] = vif.a_mem[r];

            // Capture actual DUT output
            for (int c = 0; c < N; c++)
                txn.actual[c] = vif.psum_out[c];

            // Compute expected: W.T @ act with sign extension
            for (int c = 0; c < N; c++) begin
                automatic int acc = 0;
                for (int r = 0; r < N; r++) begin
                    automatic logic signed [31:0] w32 = {{24{txn.weights[r][c][7]}}, txn.weights[r][c]};
                    automatic logic signed [31:0] a32 = {{24{txn.act[r][7]}},        txn.act[r]};
                    acc = acc + (w32 * a32);
                end
                txn.expected[c] = acc;
            end

            result_mbx.put(txn);  // send to scoreboard

            // Wait for output_valid to clear before looking for next transaction
            do @(posedge vif.clk); while (vif.output_valid);
        end
    end
endtask
```

### Why `automatic` in the loop?

Variables declared inside a loop in a class task are static by default in SV
(shared across all iterations, loop doesn't re-initialize them). `automatic` forces
stack allocation — each iteration gets its own fresh copy. Without it, w32 from
iteration r=0 bleeds into iteration r=1.

### Why does the monitor compute expected independently?

The scoreboard can't know what the correct answer is without knowing the input.
But the scoreboard has no connection to the driver. The monitor sees both:
- The inputs (via vif.w_mem/a_mem — the SRAM backing arrays)
- The outputs (via vif.psum_out)

So the monitor computes expected and packages it with actual in one transaction.
The scoreboard just compares. Clean separation of concerns.

---

## minimac_scoreboard

```systemverilog
task run_phase(uvm_phase phase);
    minimac_transaction txn;
    forever begin
        result_mbx.get(txn);   // blocking: waits for monitor to put something
        check_txn(txn);
    end
endtask

function void check_txn(minimac_transaction txn);
    for (int c = 0; c < N; c++) begin
        if (txn.actual[c] === txn.expected[c]) begin  // === handles X/Z
            pass_cnt++;
            `uvm_info("SB", $sformatf("psum_out[%0d] PASS got=%0d exp=%0d",
                c, $signed(txn.actual[c]), $signed(txn.expected[c])), UVM_MEDIUM)
        end else begin
            fail_cnt++;
            `uvm_error("SB", $sformatf("psum_out[%0d] FAIL got=%0d exp=%0d",
                c, $signed(txn.actual[c]), $signed(txn.expected[c])))
        end
    end
endfunction
```

Note `===` (case equality) vs `==` (logical equality).
`==` : X == 0 evaluates to X (unknown), not 0 or 1
`===`: X === 0 evaluates to 0 (false). If DUT output is X, it will definitely FAIL.
This is important for catching uninitialized signals.

`$signed()` for printing because the values are int32 (can be negative).
Without it, -1 would print as 4294967295.

---

## minimac_sequence + minimac_test

```systemverilog
class minimac_sequence extends uvm_sequence #(minimac_seq_item);
    int unsigned n_tests = 10;

    task body();
        repeat (n_tests) begin
            minimac_seq_item item = new("item");  // plain new(), not type_id::create()
            start_item(item);
            if (!item.randomize())
                `uvm_fatal("SEQ", "Randomization failed")
            finish_item(item);
        end
    endtask
endclass
```

`start_item` + `finish_item` is the UVM handshake for sending an item to the sequencer.
Between them you can modify the item (here we just randomize it).

```systemverilog
class minimac_test extends uvm_test;
    task run_phase(uvm_phase phase);
        minimac_sequence seq = new("seq");
        phase.raise_objection(this);
        seq.n_tests = 10;
        seq.start(env.agent.sequencer);  // runs body(), blocks until done
        #200;                            // drain any final transactions
        phase.drop_objection(this);
    endtask
endclass
```

The test is the entry point. It creates the sequence and starts it on the sequencer.
raise/drop_objection controls when the simulation ends.
