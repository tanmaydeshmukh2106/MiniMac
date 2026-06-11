// =============================================================================
// minimac_pkg.sv — UVM Environment Package for MiniMAC (mailbox-based)
// =============================================================================
// Avoids uvm_analysis_imp_decl and uvm_tlm_analysis_fifo entirely.
// Uses a plain SV mailbox shared via config_db between monitor and scoreboard.
//
// Flow:
//   sequence → seq_item (rand W + act)
//   driver   → loads SRAM models, pulses start, does handshake
//   monitor  → waits for output_valid, reads w_mem/a_mem from interface,
//              computes expected = W.T@act, captures psum_out, puts to mailbox
//   scoreboard → gets from mailbox, compares actual vs expected
// =============================================================================

package minimac_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int N = 4;

    // =========================================================================
    // minimac_seq_item — stimulus only (W matrix + activation vector)
    // =========================================================================
    class minimac_seq_item extends uvm_sequence_item;
        // No uvm_object_utils — avoids virtual method override conflict
        // with Riviera-PRO's internal UVM library

        rand byte weights [N][N];   // signed int8 weight matrix
        rand byte act     [N];      // signed int8 activation vector

        function new(string name = "minimac_seq_item");
            super.new(name);
        endfunction

    endclass : minimac_seq_item

    // =========================================================================
    // minimac_transaction — passed from monitor to scoreboard via mailbox
    // Contains both actual DUT output and expected golden output
    // =========================================================================
    class minimac_transaction extends uvm_object;
        // No uvm_object_utils — avoids virtual method override conflict

        logic [7:0]  weights [N][N];   // captured from interface w_mem
        logic [7:0]  act     [N];      // captured from interface a_mem
        logic [31:0] actual  [N];      // captured from DUT psum_out
        logic [31:0] expected[N];      // computed by monitor

        function new(string name = "minimac_transaction");
            super.new(name);
        endfunction

    endclass : minimac_transaction

    // =========================================================================
    // minimac_scoreboard — reads from mailbox, compares actual vs expected
    // No analysis ports — uses plain SV mailbox
    // =========================================================================
    class minimac_scoreboard extends uvm_component;
        `uvm_component_utils(minimac_scoreboard)

        mailbox #(minimac_transaction) result_mbx;
        int pass_cnt = 0;
        int fail_cnt = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(mailbox #(minimac_transaction))::get(
                    this, "", "result_mbx", result_mbx))
                `uvm_fatal("SB", "result_mbx not found in config_db")
        endfunction

        task run_phase(uvm_phase phase);
            minimac_transaction txn;
            forever begin
                result_mbx.get(txn);
                check_txn(txn);
            end
        endtask

        function void check_txn(minimac_transaction txn);
            `uvm_info("SB", "--- Checking transaction ---", UVM_MEDIUM)
            for (int c = 0; c < N; c++) begin
                if (txn.actual[c] === txn.expected[c]) begin
                    `uvm_info("SB", $sformatf("  psum_out[%0d] PASS  got=%0d  exp=%0d",
                        c, $signed(txn.actual[c]), $signed(txn.expected[c])), UVM_MEDIUM)
                    pass_cnt++;
                end else begin
                    `uvm_error("SB", $sformatf("  psum_out[%0d] FAIL  got=%0d  exp=%0d",
                        c, $signed(txn.actual[c]), $signed(txn.expected[c])))
                    fail_cnt++;
                end
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", "============================", UVM_NONE)
            `uvm_info("SB", $sformatf("  PASS: %0d   FAIL: %0d", pass_cnt, fail_cnt), UVM_NONE)
            `uvm_info("SB", "============================", UVM_NONE)
        endfunction

    endclass : minimac_scoreboard

    // =========================================================================
    // minimac_driver — loads SRAM models, drives start, does handshake
    // =========================================================================
    class minimac_driver extends uvm_driver #(minimac_seq_item);
        `uvm_component_utils(minimac_driver)

        virtual minimac_if #(N) vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual minimac_if #(N))::get(this, "", "vif", vif))
                `uvm_fatal("DRV", "No virtual interface found in config_db")
        endfunction

        task run_phase(uvm_phase phase);
            vif.rst_n        = 0;
            vif.start        = 0;
            vif.output_ready = 0;
            for (int i = 0; i < N*N; i++) vif.w_mem[i] = 0;
            for (int r = 0; r < N;   r++) vif.a_mem[r] = 0;
            repeat (4) @(posedge vif.clk);
            vif.rst_n = 1;
            @(posedge vif.clk);
            forever begin
                seq_item_port.get_next_item(req);
                drive_txn(req);
                seq_item_port.item_done();
            end
        endtask

        task drive_txn(minimac_seq_item item);
            // Load weight SRAM model (row-major)
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    vif.w_mem[r*N + c] = item.weights[r][c];
            // Load activation SRAM model
            for (int r = 0; r < N; r++)
                vif.a_mem[r] = item.act[r];
            // Pulse start
            @(posedge vif.clk);
            vif.start = 1;
            @(posedge vif.clk);
            vif.start = 0;
            // Wait for output_valid (500 cycle timeout)
            begin
                int timeout = 500;
                do begin
                    @(posedge vif.clk);
                    timeout--;
                    if (timeout == 0)
                        `uvm_fatal("DRV", "Timeout waiting for output_valid")
                end while (!vif.output_valid);
            end
            // Handshake
            vif.output_ready = 1;
            @(posedge vif.clk);
            vif.output_ready = 0;
            // Wait for IDLE
            do @(posedge vif.clk); while (vif.busy);
            @(posedge vif.clk);
        endtask

    endclass : minimac_driver

    // =========================================================================
    // minimac_monitor — captures output_valid, computes expected, puts to mailbox
    // Reads w_mem/a_mem directly from interface (driver already loaded them)
    // =========================================================================
    class minimac_monitor extends uvm_monitor;
        `uvm_component_utils(minimac_monitor)

        virtual minimac_if #(N) vif;
        mailbox #(minimac_transaction) result_mbx;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual minimac_if #(N))::get(this, "", "vif", vif))
                `uvm_fatal("MON", "No virtual interface found in config_db")
            if (!uvm_config_db #(mailbox #(minimac_transaction))::get(
                    this, "", "result_mbx", result_mbx))
                `uvm_fatal("MON", "result_mbx not found in config_db")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.output_valid) begin
                    minimac_transaction txn;
                    txn = new("txn");

                    // Capture weights and act from interface SRAM model
                    for (int r = 0; r < N; r++)
                        for (int c = 0; c < N; c++)
                            txn.weights[r][c] = vif.w_mem[r*N + c];
                    for (int r = 0; r < N; r++)
                        txn.act[r] = vif.a_mem[r];

                    // Capture actual DUT output
                    for (int c = 0; c < N; c++)
                        txn.actual[c] = vif.psum_out[c];

                    // Compute expected: psum_out[c] = sum_r( W[r][c] * act[r] )
                    // Sign-extend int8 to int32 before multiplying
                    for (int c = 0; c < N; c++) begin
                        automatic int acc = 0;
                        for (int r = 0; r < N; r++) begin
                            automatic logic signed [31:0] w32 =
                                {{24{txn.weights[r][c][7]}}, txn.weights[r][c]};
                            automatic logic signed [31:0] a32 =
                                {{24{txn.act[r][7]}}, txn.act[r]};
                            acc = acc + (w32 * a32);
                        end
                        txn.expected[c] = acc;
                    end

                    `uvm_info("MON", $sformatf("Captured — actual[0]=%0d exp[0]=%0d",
                        $signed(txn.actual[0]), $signed(txn.expected[0])), UVM_MEDIUM)

                    result_mbx.put(txn);

                    // Wait until output_valid clears
                    do @(posedge vif.clk); while (vif.output_valid);
                end
            end
        endtask

    endclass : minimac_monitor

    // =========================================================================
    // minimac_agent — driver + monitor + sequencer
    // =========================================================================
    class minimac_agent extends uvm_agent;
        `uvm_component_utils(minimac_agent)

        minimac_driver  driver;
        minimac_monitor monitor;
        uvm_sequencer #(minimac_seq_item) sequencer;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            driver    = minimac_driver::type_id::create("driver",    this);
            monitor   = minimac_monitor::type_id::create("monitor",  this);
            sequencer = uvm_sequencer #(minimac_seq_item)::type_id::create("sequencer", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction

    endclass : minimac_agent

    // =========================================================================
    // minimac_env — agent + scoreboard, creates shared mailbox
    // =========================================================================
    class minimac_env extends uvm_env;
        `uvm_component_utils(minimac_env)

        minimac_agent      agent;
        minimac_scoreboard scoreboard;
        mailbox #(minimac_transaction) result_mbx;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            // Create shared mailbox and put in config_db for monitor + scoreboard
            result_mbx = new(0);
            uvm_config_db #(mailbox #(minimac_transaction))::set(
                this, "*", "result_mbx", result_mbx);
            agent      = minimac_agent::type_id::create("agent",      this);
            scoreboard = minimac_scoreboard::type_id::create("scoreboard", this);
        endfunction

    endclass : minimac_env

    // =========================================================================
    // minimac_sequence — generates n_tests randomized seq_items
    // =========================================================================
    class minimac_sequence extends uvm_sequence #(minimac_seq_item);
        // No uvm_object_utils — avoids virtual method override conflict

        int unsigned n_tests = 10;

        function new(string name = "minimac_sequence");
            super.new(name);
        endfunction

        task body();
            minimac_seq_item item;
            repeat (n_tests) begin
                item = new("item");   // plain new() instead of type_id::create()
                start_item(item);
                if (!item.randomize())
                    `uvm_fatal("SEQ", "Randomization failed")
                finish_item(item);
            end
        endtask

    endclass : minimac_sequence

    // =========================================================================
    // minimac_test — top-level test
    // =========================================================================
    class minimac_test extends uvm_test;
        `uvm_component_utils(minimac_test)

        minimac_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = minimac_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            minimac_sequence seq;
            phase.raise_objection(this);
            `uvm_info("TEST", "Starting MiniMAC UVM — 10 random transactions", UVM_NONE)
            seq = new("seq");
            seq.n_tests = 10;
            seq.start(env.agent.sequencer);
            #200;
            phase.drop_objection(this);
            `uvm_info("TEST", "Done", UVM_NONE)
        endtask

    endclass : minimac_test

endpackage : minimac_pkg
