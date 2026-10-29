# sha3-fast

SIMD-parallel implementation of the **Keccak-$f[1600]$** permutation and **SHA-3 / SHAKE** sponge constructions in pure Zig, built using `comptime` and `@Vector` primitives.

## Overview

`sha3-fast` stores the 25-word Keccak state in a word-sliced layout (`st[i][k]` is 64-bit word `i` of instance `k`) so that every step ($\theta, \rho, \pi, \chi, \iota$) operates directly on `@Vector(n, u64)` lanes across `n` independent instances in lockstep:

- **`native_parallelism`**: Number of 64-bit lanes in the target CPU's widest SIMD register (`std.simd.suggestVectorLength(u64) orelse 1`, e.g., `4` on AVX2, `8` on AVX-512).
- **`KeccakF1600(n)` / `KeccakF1600Unrolled(n, unroll)`**: Runs `n` parallel 24-round (or reduced-round via `permuteR`) Keccak-$f[1600]$ permutations with configurable loop unrolling (`1..=24` rounds per iteration).
- **`Sponge(n, rate, delim)`**: Lockstep `n`-way sponge construction for absorbing equal-length messages and squeezing arbitrary output lengths (`squeeze`) or rate-sized blocks (`squeezeBlocks`).
- **`Shake128(n)` / `Shake256(n)`**: Parallel `SHAKE128` (`rate = 168`, `delim = 0x1f`) and `SHAKE256` (`rate = 136`, `delim = 0x1f`) instances suited for post-quantum cryptography workloads (such as ML-DSA and ML-KEM matrix/vector sampling).
- **`Sha3_224(n)` / `Sha3_256(n)` / `Sha3_384(n)` / `Sha3_512(n)`**: Parallel fixed-digest SHA-3 hash functions (`delim = 0x06`, digest lengths `28`, `32`, `48`, and `64` bytes respectively).

## Project Structure

- `src/keccak.zig`: Core SIMD-parallel Keccak-$f[1600]$, `Sponge`, `Shake128`, `Shake256`, `Sha3_224`, `Sha3_256`, `Sha3_384`, `Sha3_512`, and unit tests against `std.crypto`.
- `src/root.zig`: Root package module (`sha3_fast`) re-exporting the public API.
- `src/main.zig`: Example CLI executable demonstrating `n`-way `Shake256` using `native_parallelism`.
- `src/bench.zig`: Portable cycle-accurate benchmark (`x86_64`, `aarch64`, `riscv64`/`riscv32`) comparing 4-way Zig permutations (`unroll = 1` and `unroll = 4`) against Zig's scalar `std.crypto.core.keccak.KeccakF(1600)`, the CRYSTALS-Dilithium AVX2 assembly (`f1600x4.S` on `x86_64`), and `mldsa-native`'s architecture-specific Keccak implementations.

## Usage

```zig
const sha3_fast = @import("sha3_fast");

const n = sha3_fast.native_parallelism;
const Shake256xN = sha3_fast.Shake256(n);

var msgs: [n][32]u8 = undefined;
var msg_ptrs: [n]*const [32]u8 = undefined;
for (&msgs, &msg_ptrs, 0..) |*m, *p, k| {
    @memset(m, @truncate(k));
    p.* = m;
}

var out: [n][Shake256xN.block_bytes]u8 = undefined;
var out_ptrs: [n]*[Shake256xN.block_bytes]u8 = undefined;
for (&out_ptrs, &out) |*p, *o| p.* = o;

var sponge = Shake256xN.init(32, msg_ptrs);
sponge.squeezeBlocks(1, out_ptrs);
```

## Building and Testing

Run the unit test suite (validates `KeccakF1600`, `KeccakF1600Unrolled`, `Shake128`, and `Shake256` against the Zig standard library):

```sh
zig build test
```

Run the demo executable:

```sh
zig build -Doptimize=fast run
```

## Benchmarking

Build and run the Keccak-$f[1600]$ benchmark comparing against the Zig standard library only:

```bash
zig build bench-keccak -Doptimize=fast
./zig-out/bin/bench-keccak
```

It is possible to compare the performance of the implementation against the SIMD Keccak implementation used in the Dilithium [reference code](https://github.com/pq-crystals/dilithium) and the ML-DSA native [code](https://github.com/pq-code-package/mldsa-native). To do that clone the repositories somewhere on your system, e.g., into your home directory on Linux, and then use the `-Ddilithium-avx2-dir` command line flag to point at the AVX2 implementation the Dilithium reference, or `-Dmldsa-native-dir` to point at the ML-DSA native repository root directory. You can limit the feature set compiled for using `-Dcpu`, for example when you only want an AVX2 implementation even when your machine has AVX-512F, or only NEON when your machine has SVE/SVE2.

For example, this can look something like this:
```bash
zig build bench-keccak -Dcpu=x86_64+avx2 -Doptimize=fast \
  -Ddilithium-avx2-dir=$HOME/dilithium/avx2 \
  -Dmldsa-native-dir=$HOME/mldsa-native
./zig-out/bin/bench-keccak
```

Example output on an AVX2 target (`native_parallelism = 4`):

```text
native_parallelism = 4; comparing 1/2/4/8-way and native (4-way) permutations
std KeccakF(1600) scalar    :    785.5 cycles/call,   785.5 cycles/instance
Zig 1-way unroll 1          :    772.3 cycles/call,   772.3 cycles/instance
Zig 1-way unroll 2          :    749.3 cycles/call,   749.3 cycles/instance
Zig 1-way unroll 4          :    722.8 cycles/call,   722.8 cycles/instance
Zig 2-way unroll 1          :   1019.3 cycles/call,   509.6 cycles/instance
Zig 2-way unroll 2          :   1034.5 cycles/call,   517.3 cycles/instance
Zig 2-way unroll 4          :   1039.8 cycles/call,   519.9 cycles/instance
Zig 4-way unroll 1          :   1031.8 cycles/call,   257.9 cycles/instance
Zig 4-way unroll 2          :   1041.8 cycles/call,   260.4 cycles/instance
Zig 4-way unroll 4          :   1037.8 cycles/call,   259.4 cycles/instance
Zig 8-way unroll 1          :   2078.0 cycles/call,   259.8 cycles/instance
Zig 8-way unroll 2          :   2020.5 cycles/call,   252.6 cycles/instance
Zig 8-way unroll 4          :   2052.8 cycles/call,   256.6 cycles/instance
Zig native (4-way) unroll 1 :   1024.5 cycles/call,   256.1 cycles/instance
Zig native (4-way) unroll 2 :   1042.3 cycles/call,   260.6 cycles/instance
Zig native (4-way) unroll 4 :   1038.5 cycles/call,   259.6 cycles/instance
Dilithium f1600x4.S         :   1117.3 cycles/call,   279.3 cycles/instance
ML-DSA native Keccak x4     :   1099.3 cycles/call,   274.8 cycles/instance
checksum: b2bca34734155bf6
```
