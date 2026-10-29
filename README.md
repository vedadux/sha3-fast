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
zig build run
```

## Benchmarking

Build and run the Keccak-$f[1600]$ benchmark comparing against the Zig standard library only:

```sh
zig build bench-keccak -Doptimize=ReleaseFast
./zig-out/bin/bench-keccak
```

To include the external reference implementations from `dilithium/avx2` (`f1600x4.S` on `x86_64`) and `~/mldsa-native` (AVX2 on `x86_64`, NEON/v8.4-A SHA3 assembly on `aarch64`, and portable C on `riscv64`/`riscv32`):

```sh
zig build bench-keccak -Doptimize=ReleaseFast \
  -Ddilithium-avx2-dir=$HOME/dilithium/avx2 \
  -Dmldsa-native-dir=$HOME/mldsa-native
./zig-out/bin/bench-keccak
```

Example output on an AVX2 target (`native_parallelism = 4`):

```text
native_parallelism = 4; comparing four-way unroll 1 and 4
std KeccakF(1600) scalar  :    715.3 cycles/call,   715.3 cycles/instance
Zig 4-way unroll 1        :   1092.5 cycles/call,   273.1 cycles/instance
Zig 4-way unroll 4        :   1101.3 cycles/call,   275.3 cycles/instance
Dilithium f1600x4.S       :   1181.8 cycles/call,   295.4 cycles/instance
ML-DSA native Keccak x4   :   1163.8 cycles/call,   290.9 cycles/instance
checksum: 49cc27827092cb2b
```
