# =============================================================================
# matmul_ref.py — Golden Reference Model for MiniMAC Systolic Array
# =============================================================================
# Computes the expected output of the MiniMAC weight-stationary systolic array.
#
# MiniMAC computation (per the RTL):
#   psum_out[c] = sum over r of (W[r][c] * act[r])
#   In matrix form: output = W.T @ act
#   where W is NxN (int8), act is N-element vector (int8)
#   output is N-element vector (int32)
#
# Matches tb_simple.sv smoke test:
#   W[0][0]=5, act[0]=3 → output[0] = 5*3 = 15 ✓
# =============================================================================

import numpy as np


def minimac_ref(W: np.ndarray, act: np.ndarray) -> np.ndarray:
    """
    Golden reference for MiniMAC INT8 matrix-vector multiply.

    Args:
        W   : (N, N) numpy array, dtype int8  — weight matrix
        act : (N,)   numpy array, dtype int8  — activation vector (one column)

    Returns:
        out : (N,)   numpy array, dtype int32 — dot-product result per column
    """
    N = W.shape[0]
    assert W.shape == (N, N),  f"W must be ({N},{N}), got {W.shape}"
    assert act.shape == (N,),  f"act must be ({N},), got {act.shape}"

    # Sign-extend to int32 before multiply to match RTL behaviour
    W32  = W.astype(np.int32)
    a32  = act.astype(np.int32)

    # psum_out[c] = sum_r W[r][c] * act[r]  →  W.T @ act
    out = W32.T @ a32          # shape (N,), dtype int32
    return out


def clamp_int8(x: np.ndarray) -> np.ndarray:
    """Clamp values to signed int8 range [-128, 127]."""
    return np.clip(x, -128, 127).astype(np.int8)


# =============================================================================
# Quick self-test — mirrors tb_simple.sv
# =============================================================================
if __name__ == "__main__":
    N = 4

    # --- Smoke test (matches tb_simple.sv) ---
    W = np.zeros((N, N), dtype=np.int8)
    W[0][0] = 5
    act = np.zeros(N, dtype=np.int8)
    act[0] = 3

    out = minimac_ref(W, act)

    print("=== Smoke Test (matches tb_simple.sv) ===")
    print(f"W[0][0] = {W[0][0]},  act[0] = {act[0]}")
    print(f"Expected psum_out[0] = 15,  Got = {out[0]}")
    print(f"psum_out = {out.tolist()}")
    assert out[0] == 15, "FAIL: psum_out[0] should be 15"
    assert all(out[1:] == 0), "FAIL: psum_out[1..3] should be 0"
    print("PASS ✓\n")

    # --- Random matrix test ---
    rng = np.random.default_rng(42)
    W_rand = clamp_int8(rng.integers(-128, 128, size=(N, N)))
    a_rand = clamp_int8(rng.integers(-128, 128, size=(N,)))
    out_rand = minimac_ref(W_rand, a_rand)

    print("=== Random Test ===")
    print(f"W =\n{W_rand}")
    print(f"act = {a_rand.tolist()}")
    print(f"psum_out = {out_rand.tolist()}")
    print("(No assertion — visual check)")
