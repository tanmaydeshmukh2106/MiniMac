# =============================================================================
# gen_vectors.py — Test Vector Generator for MiniMAC UVM Testbench
# =============================================================================
# Generates randomized INT8 weight matrices and activation vectors,
# computes golden outputs using matmul_ref.py, and writes everything
# to .hex files loadable by the UVM testbench via $readmemh.
#
# Output files (written to golden/vectors/):
#   weights_<i>.hex   — NxN weight matrix, row-major, one int8 per line (hex)
#   act_<i>.hex       — N activation values, one int8 per line (hex)
#   expected_<i>.hex  — N int32 outputs, one per line (hex)
#   manifest.txt      — human-readable summary of all test cases
#
# Usage:
#   python gen_vectors.py                  # generates 20 random vectors
#   python gen_vectors.py --n_tests 50    # generate 50
#   python gen_vectors.py --seed 123      # fixed seed for reproducibility
# =============================================================================

import numpy as np
import os
import argparse
from matmul_ref import minimac_ref, clamp_int8

# =============================================================================
# Helpers
# =============================================================================

def to_hex8(val: int) -> str:
    """Format a signed int8 as 2-digit unsigned hex (for $readmemh)."""
    return f"{val & 0xFF:02x}"

def to_hex32(val: int) -> str:
    """Format a signed int32 as 8-digit unsigned hex (for $readmemh)."""
    return f"{val & 0xFFFFFFFF:08x}"

def write_weight_hex(path: str, W: np.ndarray):
    """Write NxN weight matrix row-major to hex file, one byte per line."""
    with open(path, "w") as f:
        for r in range(W.shape[0]):
            for c in range(W.shape[1]):
                f.write(to_hex8(int(W[r][c])) + "\n")

def write_act_hex(path: str, act: np.ndarray):
    """Write N activation values to hex file, one byte per line."""
    with open(path, "w") as f:
        for v in act:
            f.write(to_hex8(int(v)) + "\n")

def write_expected_hex(path: str, out: np.ndarray):
    """Write N int32 expected outputs to hex file, one word per line."""
    with open(path, "w") as f:
        for v in out:
            f.write(to_hex32(int(v)) + "\n")

# =============================================================================
# Corner-case generators
# =============================================================================

def make_corner_cases(N: int):
    """Return a list of (W, act, label) tuples for important edge cases."""
    cases = []

    # 1. Smoke test — matches tb_simple.sv
    W = np.zeros((N, N), dtype=np.int8)
    W[0][0] = 5
    act = np.zeros(N, dtype=np.int8)
    act[0] = 3
    cases.append((W, act, "smoke_W00x5_act0x3"))

    # 2. All zeros
    cases.append((
        np.zeros((N, N), dtype=np.int8),
        np.zeros(N, dtype=np.int8),
        "all_zeros"
    ))

    # 3. Identity weight matrix, unit activation
    cases.append((
        np.eye(N, dtype=np.int8),
        np.ones(N, dtype=np.int8),
        "identity_W_ones_act"
    ))

    # 4. Max positive weights and activations (stress test)
    cases.append((
        np.full((N, N), 127, dtype=np.int8),
        np.full(N, 127, dtype=np.int8),
        "max_positive"
    ))

    # 5. Max negative weights, max positive activations
    cases.append((
        np.full((N, N), -128, dtype=np.int8),
        np.full(N, 127, dtype=np.int8),
        "max_neg_weight_pos_act"
    ))

    # 6. Alternating signs
    W_alt = np.array([[(1 if (r+c)%2==0 else -1) * (r*N+c+1)
                        for c in range(N)] for r in range(N)], dtype=np.int8)
    act_alt = np.array([(1 if i%2==0 else -1) * (i+1)
                         for i in range(N)], dtype=np.int8)
    cases.append((W_alt, act_alt, "alternating_signs"))

    return cases

# =============================================================================
# Main
# =============================================================================

def generate(n_tests: int = 20, N: int = 4, seed: int = 42,
             out_dir: str = None):

    if out_dir is None:
        out_dir = os.path.join(os.path.dirname(__file__), "vectors")
    os.makedirs(out_dir, exist_ok=True)

    rng = np.random.default_rng(seed)
    manifest_lines = []
    test_idx = 0

    # ── Corner cases first ────────────────────────────────────────────────────
    corners = make_corner_cases(N)
    print(f"Generating {len(corners)} corner-case vectors...")
    for W, act, label in corners:
        out = minimac_ref(W, act)
        write_weight_hex(os.path.join(out_dir, f"weights_{test_idx:03d}.hex"), W)
        write_act_hex   (os.path.join(out_dir, f"act_{test_idx:03d}.hex"),     act)
        write_expected_hex(os.path.join(out_dir, f"expected_{test_idx:03d}.hex"), out)
        manifest_lines.append(
            f"[{test_idx:03d}] CORNER  {label:35s} | "
            f"out={out.tolist()}"
        )
        test_idx += 1

    # ── Random vectors ────────────────────────────────────────────────────────
    n_random = max(0, n_tests - len(corners))
    print(f"Generating {n_random} random vectors...")
    for _ in range(n_random):
        W   = clamp_int8(rng.integers(-128, 128, size=(N, N)))
        act = clamp_int8(rng.integers(-128, 128, size=(N,)))
        out = minimac_ref(W, act)
        write_weight_hex(os.path.join(out_dir, f"weights_{test_idx:03d}.hex"), W)
        write_act_hex   (os.path.join(out_dir, f"act_{test_idx:03d}.hex"),     act)
        write_expected_hex(os.path.join(out_dir, f"expected_{test_idx:03d}.hex"), out)
        manifest_lines.append(
            f"[{test_idx:03d}] RANDOM  {'':35s} | "
            f"out={out.tolist()}"
        )
        test_idx += 1

    # ── Write manifest ────────────────────────────────────────────────────────
    manifest_path = os.path.join(out_dir, "manifest.txt")
    with open(manifest_path, "w") as f:
        f.write(f"MiniMAC Test Vectors  N={N}  seed={seed}  total={test_idx}\n")
        f.write("=" * 70 + "\n")
        f.write("\n".join(manifest_lines) + "\n")

    print(f"\nDone. {test_idx} test vectors written to: {out_dir}/")
    print(f"Manifest: {manifest_path}")
    return test_idx


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MiniMAC test vector generator")
    parser.add_argument("--n_tests", type=int, default=20,
                        help="Total number of test vectors (includes corner cases)")
    parser.add_argument("--N",       type=int, default=4,
                        help="Array dimension (must match RTL parameter)")
    parser.add_argument("--seed",    type=int, default=42,
                        help="Random seed for reproducibility")
    parser.add_argument("--out_dir", type=str, default=None,
                        help="Output directory (default: golden/vectors/)")
    args = parser.parse_args()

    generate(n_tests=args.n_tests, N=args.N, seed=args.seed, out_dir=args.out_dir)
