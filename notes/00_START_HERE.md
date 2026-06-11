# MiniMAC Study Notes — Index

Read these in order the first time through. After that use them as reference.

```
00_START_HERE.md              ← you are here

01_concept/
  what_minimac_computes.md    ← the math, why it matters for AI
  systolic_array_idea.md      ← what a systolic array is, why use one

02_rtl/
  pe.md                       ← processing element, line by line
  sys_array.md                ← how the PE grid is wired
  controller.md               ← FSM, every state, every counter
  minimac_top.md              ← top wrapper + output accumulator

03_timing/
  pipeline_timing.md          ← THE most important file. cycle-by-cycle trace
                                 of why the original design failed and exactly
                                 how the fix makes it work

04_uvm/
  uvm_architecture.md         ← what UVM is and how this testbench is structured
  classes_explained.md        ← every class: what it does, key lines of code

05_golden/
  python_model.md             ← matmul_ref.py and gen_vectors.py explained

06_bugs/
  all_bugs.md                 ← all 4 bugs: original code, symptom, root cause, fix
```

## How to use these notes for interviews

The three things an interviewer will drill on for this project:

1. **"How does a systolic array work?"**
   → Read 01_concept/ then 03_timing/

2. **"You mentioned a bug — walk me through it."**
   → Bug 3 in 06_bugs/ is the answer. Know it cold.

3. **"What does UVM give you over a plain testbench?"**
   → Read 04_uvm/uvm_architecture.md

Everything else (signal widths, FSM states, Python model) is supporting detail
that you should be able to refer to, not memorize.
