# Python Golden Model

## Purpose

The Python golden model is an INDEPENDENT implementation of the same computation
the RTL does. It doesn't simulate SystemVerilog — it just does the math in Python.

Why? Two reasons:
1. To generate test vectors (.hex files) you can load into a testbench
2. To verify the UVM monitor's expected computation is correct (both use numpy)

## matmul_ref.py

```python
def minimac_ref(W: np.ndarray, act: np.ndarray) -> np.ndarray:
    W32  = W.astype(np.int32)    # sign-extend int8 to int32
    a32  = act.astype(np.int32)  # sign-extend int8 to int32
    out  = W32.T @ a32           # matrix multiply: (W transposed) times act
    return out                   # shape (N,), dtype int32
```

### Why .astype(np.int32) before multiplying?

numpy int8 overflow silently:
```python
np.int8(127) * np.int8(127) = np.int8(-2)   # overflow! 16129 doesn't fit in int8
```

Cast to int32 first:
```python
np.int32(127) * np.int32(127) = np.int32(16129)  # correct
```

This matches what the RTL does: sign-extend to 32 bits before the multiply.

### Why W.T @ act (W transposed times act)?

The formula is: output[c] = sum_r W[r][c] * act[r]

In matrix form, this is a dot product of column c of W with act.
Stacking all columns: output = W.T @ act

NumPy: `@` is the matrix multiply operator. `W.T` transposes W.

### Self-test in matmul_ref.py

```python
W = zeros(4,4); W[0][0] = 5
act = zeros(4);  act[0] = 3
out = minimac_ref(W, act)
assert out[0] == 15    # 5*3 = 15
assert all(out[1:] == 0)
```

Mirrors the tb_simple.sv smoke test. If this fails, the golden model is wrong.

---

## gen_vectors.py

Generates test vectors as .hex files in golden/vectors/.

### Output files per test case i:

```
weights_000.hex   N×N bytes, row-major, one int8 per line as 2-char hex
act_000.hex       N bytes, one int8 per line as 2-char hex
expected_000.hex  N int32 words, one per line as 8-char hex
```

### Hex format

int8 as unsigned hex (for $readmemh):
```python
def to_hex8(val: int) -> str:
    return f"{val & 0xFF:02x}"   # & 0xFF makes negatives unsigned
```

-1 in int8 = 0xFF = "ff". $readmemh reads this as 8'hFF = -1 when the target
is a signed type. Correct.

int32 as unsigned hex:
```python
def to_hex32(val: int) -> str:
    return f"{val & 0xFFFFFFFF:08x}"
```

-1 in int32 = "ffffffff". $readmemh reads as 32'hFFFFFFFF = -1.

### Corner cases generated first

```python
cases = [
    smoke_test,          # W[0][0]=5, act[0]=3 → output[0]=15
    all_zeros,           # everything 0 → output all 0
    identity_W_ones_act, # W=I, act=ones → output=ones
    max_positive,        # W=127, act=127 → output=N*127*127
    max_neg_weight,      # W=-128, act=127 → output=N*(-128)*127
    alternating_signs,   # mixed signs, tests sign handling
]
```

Then random cases fill the rest up to n_tests.

### Why corner cases matter

The smoke test (only W[0][0] active) was fine even with the broken RTL —
because there was only one PE contributing, so accumulation didn't matter.
The full random tests are what exposed Bug 3.

Max positive (W=127, act=127, N=4): output = 4 × 127 × 127 = 64,516.
This is well within int32 range (2B+) but would overflow int16 (max 32767).
Confirms you need int32 accumulators.

---

## How Python vectors relate to UVM

The UVM testbench generates its OWN random stimuli on the fly (via randomize()).
It doesn't load from the .hex files.

So why generate .hex files at all?

1. The .hex files serve as pre-computed reference points you can check manually.
   Open expected_000.hex, verify it matches W.T @ act by hand.

2. For a more formal testbench (future extension), you could write a UVM sequence
   that loads from .hex files instead of randomizing — giving you reproducible,
   fixed test cases. The infrastructure is there.

3. They demonstrate that the Python model independently agrees with the UVM monitor's
   expected computation. Both use the same formula. If Python says 3176 and the
   monitor says 3176, and the DUT also says 3176, you've closed the loop.

## Running the golden model

```bash
# From the MiniMAC directory:
python golden/matmul_ref.py      # self-test, prints PASS
python golden/gen_vectors.py     # 20 vectors (6 corners + 14 random)
python golden/gen_vectors.py --n_tests 50 --seed 99   # custom
```
