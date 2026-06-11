# What MiniMAC Computes

## The operation

MiniMAC computes a matrix-vector multiply:

```
output = W.T @ act

where:
  W   is N×N, dtype int8   (the weight matrix)
  act is N×1, dtype int8   (the activation vector)
  out is N×1, dtype int32  (the result)
```

Element-wise: `output[c] = sum over r of ( W[r][c] * act[r] )`

For N=4, written out fully:

```
output[0] = W[0][0]*act[0] + W[1][0]*act[1] + W[2][0]*act[2] + W[3][0]*act[3]
output[1] = W[0][1]*act[0] + W[1][1]*act[1] + W[2][1]*act[2] + W[3][1]*act[3]
output[2] = W[0][2]*act[0] + W[1][2]*act[1] + W[2][2]*act[2] + W[3][2]*act[3]
output[3] = W[0][3]*act[0] + W[1][3]*act[1] + W[2][3]*act[2] + W[3][3]*act[3]
```

Each output[c] is a dot product between column c of W and the activation vector.

## Why int8 × int8 → int32

int8 range: -128 to 127
Worst case product: -128 × -128 = 16384
Sum of 4 such products: up to 4 × 16384 = 65536

That fits in int32 (-2,147,483,648 to 2,147,483,647) with huge headroom.
int16 would overflow for large N. int32 is standard for accumulation.

## Why this matters for AI

Every linear layer in a neural network does: output = weight_matrix @ input_vector
Every convolution can be rewritten as a matrix multiply (im2col).
Attention (Q,K,V) is three matrix multiplies.

So this single operation — matmul — is literally 90%+ of the compute in
transformer inference, CNN inference, etc. Every AI chip (TPU, NPU, GPU tensor core)
has dedicated silicon for exactly this.

## What "weight-stationary" means

There are different ways to schedule a matmul on a systolic array:

- Weight-stationary: load weights once into the PEs, keep them there.
  Stream activations through. Good when you reuse the same weights many times
  (inference — same model, different inputs every time).

- Output-stationary: each PE accumulates one output element locally.

- Input-stationary: keep activations fixed, stream weights.

MiniMAC uses weight-stationary because it maps cleanly to inference:
load the model weights once, then run many different activation vectors through.

## Smoke test sanity check

Simplest possible test: only W[0][0] = 5, act[0] = 3, everything else 0.

output[0] = W[0][0]*act[0] = 5*3 = 15
output[1] = output[2] = output[3] = 0

This was the first thing verified in tb_simple.sv. If this fails, nothing else matters.
