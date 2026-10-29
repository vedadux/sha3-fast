//! Root module for `sha3_fast`, exposing SIMD-parallel Keccak-f[1600],
//! SHA-3/SHAKE sponge constructions, and `Shake128`/`Shake256`.
const std = @import("std");

pub const keccak = @import("keccak.zig");

pub const native_parallelism = keccak.native_parallelism;
pub const KeccakF1600 = keccak.KeccakF1600;
pub const KeccakF1600Unrolled = keccak.KeccakF1600Unrolled;
pub const Sponge = keccak.Sponge;
pub const Shake128 = keccak.Shake128;
pub const Shake256 = keccak.Shake256;
pub const Sha3 = keccak.Sha3;
pub const Sha3_224 = keccak.Sha3_224;
pub const Sha3_256 = keccak.Sha3_256;
pub const Sha3_384 = keccak.Sha3_384;
pub const Sha3_512 = keccak.Sha3_512;

test {
    std.testing.refAllDecls(@This());
}

