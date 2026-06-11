# Interview Q&A — MiniMAC

These are the questions you will actually get. Practice saying these out loud.

---

## "Walk me through your MiniMAC project."

Start here:

"MiniMAC is a weight-stationary systolic array that computes a matrix-vector multiply
in hardware. The target operation is W.T @ act — that's the core of every linear layer
in a neural network. I implemented it in SystemVerilog with a parameterized NxN PE grid,
a controller FSM, and a full UVM verification environment. I verified it on Riviera-PRO
and got PASS:40 FAIL:0 — 10 random transactions, 4 outputs each."

Then stop and let them ask a follow-up.

---

## "What is a systolic array?"

"It's a grid of simple processing elements where data flows rhythmically through the
array like a heartbeat — systolic comes from the cardiac term. Each PE does one MAC
per cycle: multiplies its local weight by an incoming activation and adds that to a
partial sum flowing in from above. The activation passes rightward, the partial sum
passes downward. At the bottom of each column you get the full dot product. The key
benefit is you get N² MACs running in parallel with no global interconnect — data
only moves to adjacent PEs, so it scales well."

---

## "What does weight-stationary mean?"

"The weights are loaded into PE registers once before the computation starts and they
don't move for the duration. Activations stream through the array, each row's activation
passing left to right. This is good for inference — same model weights, many different
input activations. You pay the weight-load cost once and amortize it across many
activation vectors."

---

## "Tell me about a bug you found and fixed."

This is where you spend time. Use Bug 3.

"The most interesting bug was in the pipeline timing. My original PE had two input
pipeline registers — one for act_in and one for psum_in — before the MAC. And my
activation interface was delivering all N rows' activations simultaneously on cycle 0.

The problem: with 2-stage PE, psum_reg latches psum_in one cycle before the MAC uses
it. So when act[1] arrived at PE[1][0] on cycle 0 and psum_reg latched psum_in at
posedge 0, it captured PE[0][0]'s output BEFORE posedge 0 — which was 0. PE[0][0]
only produced W[0][0]*act[0] AT posedge 0. They were always exactly one cycle apart.
Every PE computed its product in isolation, nothing ever accumulated. This gave me
PASS:0 FAIL:40 with plausible-looking but wrong outputs.

The fix had three parts. First I removed the input registers from the PE so psum_in
and act_in feed the MAC directly — psum_in is now a combinational wire, so the output
of PE[r-1] is immediately visible to PE[r] in the same cycle. Second I changed the
activation interface from delivering all rows simultaneously to row-skewed delivery:
row r gets its activation only when a_col equals r. The controller increments a_col
each cycle, so row 0 gets its act on cycle 0, row 1 on cycle 1, and so on. Now when
act[r] arrives at PE[r][0], the partial sum from rows 0 to r-1 is already sitting
on the wire from PE[r-1][0]. They combine in the same cycle. Third I added an output
accumulator in minimac_top because with single-stage PEs, each column's result only
exists for one cycle — the accumulator catches these one-cycle pulses and holds them
until output_valid."

---

## "What is UVM and why use it over a plain testbench?"

"UVM is a SystemVerilog class library that provides a standardized structure for
verification environments. The main benefits over a plain testbench are:

Randomization — you declare stimulus fields as rand and the constraint solver
generates legal random values automatically. I ran 10 random transactions without
writing a single test case by hand.

Separation of concerns — the driver only drives, the monitor only observes, the
scoreboard only checks. If the DUT interface changes I only touch the driver, not
the whole testbench.

Reusability — the agent, scoreboard, and sequence can be reused for related DUTs
or extended with different sequences.

In my implementation I used a mailbox instead of UVM analysis ports for the
monitor-to-scoreboard connection because UVM TLM infrastructure had macro conflicts
with Riviera-PRO's internal UVM version. Same functionality, cleaner implementation."

---

## "Why does your PE use a single pipeline stage?"

"Originally it had two stages — input registers for both act_in and psum_in, then an
output register on the MAC result. The problem is that with two stages, there's a
one-cycle gap between when a row's activation arrives and when the partial sum from
the previous row is available. They can never be in the PE at the same time to combine.
With a single output-only register, psum_in is a direct wire from the PE above, visible
in the same cycle as act_in. That alignment is what makes the accumulation correct."

---

## "Why sign-extend int8 to int32 before multiplying?"

"INT8 range is -128 to 127. The product of two INT8 values can be as large as
-128 times -128 = 16384. Sum of N=4 such products: up to 65536. That doesn't fit in
INT16 (max 32767) but fits comfortably in INT32. More importantly, if you multiply
two 8-bit signed values without sign extension, the hardware treats the bits as unsigned
and gives the wrong result for negative inputs. Sign-extending to 32 bits before the
multiply — replicating the sign bit 24 times — ensures the multiplier sees the correct
signed representation."

---

## "What does the controller FSM do?"

"Five states: IDLE, LOAD_WEIGHTS, STREAM_ACT, ACCUMULATE, OUTPUT_VALID.
In LOAD_WEIGHTS it counts through all N-squared weight addresses, presenting each
weight to its target PE via weight_ld and weight_in — 16 cycles for N=4.
In STREAM_ACT it increments a_col from 0 to N-1, which causes the activation SRAM
interface to deliver each row's activation on its corresponding cycle — 4 cycles.
In ACCUMULATE it waits N cycles for the pipeline to drain — the last column's result
arrives at cycle 2N-2 from STREAM_ACT start, within the N-cycle flush window.
Then OUTPUT_VALID asserts and holds until the host acknowledges with output_ready."

---

## "What would you add if you had more time?"

Good honest answer:
"Formal properties — SVA assertions like output_valid never fires before STREAM_ACT
completes, psum_out is never X when output_valid is high. Also functional coverage
to measure what fraction of the INT8 input space I've exercised. And parameterizing
to N=8 or N=16 to verify the design scales. The architecture is already parameterized
— just changing N and rerunning would be the test."
