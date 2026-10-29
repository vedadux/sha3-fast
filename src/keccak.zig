//! SIMD-parallel Keccak-f[1600] built on `@Vector`.
//!
//! `KeccakF1600(n)` runs `n` independent permutations at once. The state is stored
//! word-sliced: `st[i][k]` is 64-bit word `i` of instance `k`, so every Keccak step
//! operates on whole vectors, exactly like the 4-way AVX2 code (`f1600x4.S`) but
//! for any width. Pick `n = native_parallelism` to fill one SIMD register per word,
//! or a multiple of it to let LLVM split each word over several registers.
//! `KeccakF1600Unrolled(n, unroll)` allows target-specific round-unroll tuning;
//! `KeccakF1600(n)` retains a portable one-round-per-iteration default.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

/// Number of 64-bit lanes in the widest SIMD register of the target CPU.
pub const native_parallelism: u16 = std.simd.suggestVectorLength(u64) orelse 1;

const round_constants = [24]u64{
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
};

/// rho rotation offset of word `x + 5 * y`.
const rho_offsets: [25]u6 = blk: {
    var r: [25]u6 = @splat(0);
    var x: usize = 1;
    var y: usize = 0;
    for (0..24) |t| {
        r[x + 5 * y] = @intCast(((t + 1) * (t + 2) / 2) % 64);
        const nx = y;
        y = (2 * x + 3 * y) % 5;
        x = nx;
    }
    break :blk r;
};

/// The Keccak-f[1600] permutation applied to `n` independent states in parallel,
/// using one round per loop iteration.
pub fn KeccakF1600(comptime n: u16) type {
    return KeccakF1600Unrolled(n, 1);
}

/// Like `KeccakF1600`, with `unroll` rounds per loop iteration (1 to 24).
pub fn KeccakF1600Unrolled(comptime n: u16, comptime unroll: u5) type {
    comptime {
        assert(n >= 1);
        assert(unroll >= 1 and unroll <= 24);
    }

    return struct {
        const Self = @This();

        /// Number of states permuted in parallel.
        pub const parallelism = n;
        /// One 64-bit word position across all `n` instances.
        pub const Lane = @Vector(n, u64);
        /// Number of bytes in a single instance's state.
        pub const block_bytes = 200;
        pub const max_rounds = 24;

        st: [25]Lane = @splat(@splat(0)),

        /// Initialize every instance from its own 200-byte state.
        pub fn init(bytes: *const [n][block_bytes]u8) Self {
            var self: Self = .{};
            self.setBytes(block_bytes, toConstSlices(block_bytes, bytes));
            return self;
        }

        /// Overwrite the first `len` bytes of each instance with `inputs[k]`.
        pub fn setBytes(self: *Self, comptime len: usize, inputs: [n]*const [len]u8) void {
            comptime assert(len <= block_bytes);
            self.clear(0, len);
            self.addBytes(len, inputs);
        }

        /// XOR `inputs[k]` into the first `len` bytes of instance `k`.
        pub fn addBytes(self: *Self, comptime len: usize, inputs: [n]*const [len]u8) void {
            comptime assert(len <= block_bytes);
            inline for (0..len / 8) |i| {
                var w: [n]u64 = undefined;
                inline for (0..n) |k| w[k] = mem.readInt(u64, inputs[k][8 * i ..][0..8], .little);
                self.st[i] ^= @as(Lane, w);
            }
            if (len % 8 != 0) {
                var w: [n]u64 = undefined;
                inline for (0..n) |k| {
                    var padded: [8]u8 = @splat(0);
                    padded[0 .. len % 8].* = inputs[k][len - len % 8 ..][0 .. len % 8].*;
                    w[k] = mem.readInt(u64, &padded, .little);
                }
                self.st[len / 8] ^= @as(Lane, w);
            }
        }

        /// XOR the same byte into every instance at a given offset.
        pub fn addByte(self: *Self, byte: u8, offset: usize) void {
            const shift: u6 = @intCast(8 * (offset % 8));
            self.st[offset / 8] ^= @splat(@as(u64, byte) << shift);
        }

        /// Copy the first `len` bytes of instance `k` into `outputs[k]`.
        pub fn extractBytes(self: *const Self, comptime len: usize, outputs: [n]*[len]u8) void {
            comptime assert(len <= block_bytes);
            inline for (0..len / 8) |i| {
                const w: [n]u64 = self.st[i];
                inline for (0..n) |k| mem.writeInt(u64, outputs[k][8 * i ..][0..8], w[k], .little);
            }
            if (len % 8 != 0) {
                const w: [n]u64 = self.st[len / 8];
                inline for (0..n) |k| {
                    var padded: [8]u8 = undefined;
                    mem.writeInt(u64, &padded, w[k], .little);
                    outputs[k][len - len % 8 ..][0 .. len % 8].* = padded[0 .. len % 8].*;
                }
            }
        }

        /// Zero the words covering bytes `[from, to)` in every instance.
        pub fn clear(self: *Self, from: usize, to: usize) void {
            @memset(self.st[from / 8 .. (to + 7) / 8], @splat(0));
        }

        /// Clear the entire state, disabling compiler optimizations.
        pub fn secureZero(self: *Self) void {
            std.crypto.secureZero(Lane, &self.st);
        }

        inline fn rotl(x: Lane, comptime r: u6) Lane {
            if (r == 0) return x;
            return (x << @splat(r)) | (x >> @splat(@as(u6, @intCast(64 - @as(u7, r)))));
        }

        inline fn round(a: *[25]Lane, rc: u64) void {
            var c: [5]Lane = undefined;
            inline for (0..5) |x| c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
            var d: [5]Lane = undefined;
            inline for (0..5) |x| {
                d[x] = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
            }

            // Preserve the old state until every output row has been computed.
            var next: [25]Lane = undefined;
            inline for (0..5) |y| {
                var row: [5]Lane = undefined;
                inline for (0..5) |x| {
                    // Invert pi: B[x, y] comes from A[(3y + x) mod 5, x].
                    const source_x = (3 * y + x) % 5;
                    const source = source_x + 5 * x;
                    row[x] = rotl(a[source] ^ d[source_x], rho_offsets[source]);
                }
                inline for (0..5) |x|
                    next[x + 5 * y] = row[x] ^ (~row[(x + 1) % 5] & row[(x + 2) % 5]);
            }

            next[0] ^= @splat(rc);
            a.* = next;
        }

        /// Apply the last `rounds` rounds of Keccak-f[1600] to every instance.
        pub fn permuteR(self: *Self, comptime rounds: u5) void {
            @setEvalBranchQuota(100000);
            comptime assert(rounds <= max_rounds);
            var a = self.st;
            var i: usize = max_rounds - rounds;
            while (i + unroll <= max_rounds) : (i += unroll) {
                inline for (0..unroll) |j| round(&a, round_constants[i + j]);
            }
            while (i < max_rounds) : (i += 1) {
                round(&a, round_constants[i]);
            }
            self.st = a;
        }

        /// Apply the full 24-round Keccak-f[1600] to every instance.
        pub fn permute(self: *Self) void {
            self.permuteR(max_rounds);
        }

        fn toConstSlices(comptime len: usize, arrays: *const [n][len]u8) [n]*const [len]u8 {
            var r: [n]*const [len]u8 = undefined;
            inline for (0..n) |k| r[k] = &arrays[k];
            return r;
        }
    };
}

/// `n` parallel SHAKE / SHA-3 style sponges over Keccak-f[1600] with 24 rounds.
/// All instances absorb messages of the same length and squeeze in lockstep.
pub fn Sponge(comptime n: u16, comptime rate: usize, comptime delim: u8) type {
    comptime assert(rate > 0 and rate < 200 and rate % 8 == 0);

    return struct {
        const Self = @This();
        pub const F = KeccakF1600(n);
        pub const block_bytes = rate;

        st: F = .{},

        /// Absorb one complete message per instance and apply the padding.
        pub fn init(comptime len: usize, inputs: [n]*const [len]u8) Self {
            var self: Self = .{};
            inline for (0..len / rate) |blk| {
                var chunk: [n]*const [rate]u8 = undefined;
                inline for (0..n) |k| chunk[k] = inputs[k][blk * rate ..][0..rate];
                self.st.addBytes(rate, chunk);
                self.st.permute();
            }
            const tail = len % rate;
            if (tail != 0) {
                var chunk: [n]*const [tail]u8 = undefined;
                inline for (0..n) |k| chunk[k] = inputs[k][len - tail ..][0..tail];
                self.st.addBytes(tail, chunk);
            }
            self.st.addByte(delim, tail);
            self.st.addByte(0x80, rate - 1);
            return self;
        }

        /// Squeeze `out_len` bytes into each output.
        pub fn squeeze(self: *Self, comptime out_len: usize, outputs: [n]*[out_len]u8) void {
            inline for (0..out_len / rate) |blk| {
                self.st.permute();
                var chunk: [n]*[rate]u8 = undefined;
                inline for (0..n) |k| chunk[k] = outputs[k][blk * rate ..][0..rate];
                self.st.extractBytes(rate, chunk);
            }
            const rem = out_len % rate;
            if (rem != 0) {
                self.st.permute();
                var chunk: [n]*[rem]u8 = undefined;
                inline for (0..n) |k| chunk[k] = outputs[k][out_len - rem ..][0..rem];
                self.st.extractBytes(rem, chunk);
            }
        }

        /// Squeeze `blocks` full rate-sized blocks into each output.
        pub fn squeezeBlocks(self: *Self, comptime blocks: usize, outputs: [n]*[blocks * rate]u8) void {
            self.squeeze(blocks * rate, outputs);
        }

        /// Absorb `len`-byte inputs and squeeze `out_len` bytes per instance in one shot.
        pub fn hash(comptime len: usize, inputs: [n]*const [len]u8, comptime out_len: usize, outputs: [n]*[out_len]u8) void {
            var self = Self.init(len, inputs);
            self.squeeze(out_len, outputs);
        }
    };
}

/// `n` parallel SHAKE128 instances.
pub fn Shake128(comptime n: u16) type {
    return Sponge(n, 168, 0x1f);
}

/// `n` parallel SHAKE256 instances.
pub fn Shake256(comptime n: u16) type {
    return Sponge(n, 136, 0x1f);
}

/// `n` parallel SHA-3 instances with a fixed `digest_bytes` output size.
pub fn Sha3(comptime n: u16, comptime digest_bytes: usize) type {
    comptime assert(digest_bytes == 28 or digest_bytes == 32 or digest_bytes == 48 or digest_bytes == 64);
    const rate = 200 - 2 * digest_bytes;

    return struct {
        const Self = @This();
        pub const F = KeccakF1600(n);
        pub const InnerSponge = Sponge(n, rate, 0x06);
        pub const block_bytes = rate;
        pub const digest_length = digest_bytes;

        st: F = .{},

        /// Absorb one complete message per instance and apply the SHA-3 padding.
        pub fn init(comptime len: usize, inputs: [n]*const [len]u8) Self {
            const sponge = InnerSponge.init(len, inputs);
            return .{ .st = sponge.st };
        }

        /// Permute and extract the `digest_length`-byte digest for each instance.
        pub fn final(self: *Self, outputs: [n]*[digest_length]u8) void {
            self.st.permute();
            self.st.extractBytes(digest_length, outputs);
        }

        /// Compute the SHA-3 digest of `n` equal-length messages in one shot.
        pub fn hash(comptime len: usize, inputs: [n]*const [len]u8, outputs: [n]*[digest_length]u8) void {
            var self = Self.init(len, inputs);
            self.final(outputs);
        }
    };
}

/// `n` parallel SHA3-224 instances.
pub fn Sha3_224(comptime n: u16) type {
    return Sha3(n, 28);
}

/// `n` parallel SHA3-256 instances.
pub fn Sha3_256(comptime n: u16) type {
    return Sha3(n, 32);
}

/// `n` parallel SHA3-384 instances.
pub fn Sha3_384(comptime n: u16) type {
    return Sha3(n, 48);
}

/// `n` parallel SHA3-512 instances.
pub fn Sha3_512(comptime n: u16) type {
    return Sha3(n, 64);
}

const testing = std.testing;

fn testPermutationAgainstStd(comptime n: u16, comptime unroll: u5) !void {
    const Ref = std.crypto.core.keccak.KeccakF(1600);
    var prng = std.Random.DefaultPrng.init(0x5eed + n);
    const random = prng.random();

    var states: [n][200]u8 = undefined;
    for (&states) |*s| random.bytes(s);

    const F = KeccakF1600Unrolled(n, unroll);
    var par = F.init(&states);
    par.permute();
    par.permute();
    var out: [n][200]u8 = undefined;
    var out_ptrs: [n]*[200]u8 = undefined;
    for (&out_ptrs, &out) |*p, *o| p.* = o;
    par.extractBytes(200, out_ptrs);

    for (states, out) |s, o| {
        var ref = Ref.init(s);
        ref.permute();
        ref.permute();
        var expected: [200]u8 = undefined;
        ref.extractBytes(&expected);
        try testing.expectEqualSlices(u8, &expected, &o);
    }

    // std's permuteR batches three rounds and requires counts divisible by three.
    inline for (.{ 3, 12 }) |rounds| {
        var reduced = F.init(&states);
        reduced.permuteR(rounds);
        reduced.extractBytes(200, out_ptrs);
        for (states, out) |s, o| {
            var ref = Ref.init(s);
            ref.permuteR(rounds);
            var expected: [200]u8 = undefined;
            ref.extractBytes(&expected);
            try testing.expectEqualSlices(u8, &expected, &o);
        }
    }
    inline for (.{ 1, 7, 23 }) |rounds| {
        var reduced = F.init(&states);
        reduced.permuteR(rounds);
        reduced.extractBytes(200, out_ptrs);
        for (states, out) |s, o| {
            var scalar = KeccakF1600(1).init(&.{s});
            scalar.permuteR(rounds);
            var expected: [1][200]u8 = undefined;
            scalar.extractBytes(200, .{&expected[0]});
            try testing.expectEqualSlices(u8, &expected[0], &o);
        }
    }
}

test "KeccakF1600 matches std Keccak-f[1600]" {
    try testPermutationAgainstStd(1, 1);
    try testPermutationAgainstStd(2, 1);
    try testPermutationAgainstStd(3, 1);
    try testPermutationAgainstStd(4, 1);
    try testPermutationAgainstStd(8, 1);
    try testPermutationAgainstStd(native_parallelism, 1);
    inline for (.{ 2, 3, 4, 5, 6, 8, 12, 24 }) |unroll| {
        try testPermutationAgainstStd(4, unroll);
        try testPermutationAgainstStd(native_parallelism, unroll);
    }
}

test "KeccakF1600 zero-state known answer" {
    var st: KeccakF1600(2) = .{};
    st.permute();
    try testing.expectEqual(@as(u64, 0xF1258F7940E1DDE7), st.st[0][0]);
    try testing.expectEqual(@as(u64, 0xEAF1FF7B5CECA249), st.st[24][1]);
}

fn testShakeAgainstStd(
    comptime ParShake: fn (comptime u16) type,
    comptime StdShake: type,
    comptime n: u16,
    comptime len: usize,
    comptime out_len: usize,
) !void {
    const S = ParShake(n);
    var prng = std.Random.DefaultPrng.init(len * 31 + out_len * 13 + n);
    const random = prng.random();

    var msgs: [n][len]u8 = undefined;
    var msg_ptrs: [n]*const [len]u8 = undefined;
    for (&msgs, &msg_ptrs) |*m, *p| {
        random.bytes(m);
        p.* = m;
    }
    var out: [n][out_len]u8 = undefined;
    var out_ptrs: [n]*[out_len]u8 = undefined;
    for (&out_ptrs, &out) |*p, *o| p.* = o;

    S.hash(len, msg_ptrs, out_len, out_ptrs);

    for (msgs, out) |m, o| {
        var expected: [out_len]u8 = undefined;
        StdShake.hash(&m, &expected, .{});
        try testing.expectEqualSlices(u8, &expected, &o);
    }
}

test "parallel SHAKE128 matches std" {
    const rate = Shake128(1).block_bytes;
    inline for (.{ 1, 2, 3, 4, 8, native_parallelism }) |n| {
        inline for (.{ 0, 1, 34, rate - 1, rate, rate + 1, 400 }) |len| {
            inline for (.{ 32, rate, 2 * rate, 2 * rate + 29 }) |out_len| {
                try testShakeAgainstStd(Shake128, std.crypto.hash.sha3.Shake128, n, len, out_len);
            }
        }
    }
}

test "parallel SHAKE256 matches std" {
    const rate = Shake256(1).block_bytes;
    inline for (.{ 1, 2, 3, 4, 8, native_parallelism }) |n| {
        inline for (.{ 0, 1, 66, rate - 1, rate, rate + 1, 300 }) |len| {
            inline for (.{ 32, rate, 2 * rate, 2 * rate + 29 }) |out_len| {
                try testShakeAgainstStd(Shake256, std.crypto.hash.sha3.Shake256, n, len, out_len);
            }
        }
    }
}

fn testSha3AgainstStd(
    comptime ParHash: fn (comptime u16) type,
    comptime StdHash: type,
    comptime n: u16,
    comptime len: usize,
) !void {
    const H = ParHash(n);
    const digest_len = H.digest_length;

    var prng = std.Random.DefaultPrng.init(len * 53 + n * 17 + digest_len);
    const random = prng.random();

    var msgs: [n][len]u8 = undefined;
    var msg_ptrs: [n]*const [len]u8 = undefined;
    for (&msgs, &msg_ptrs) |*m, *p| {
        random.bytes(m);
        p.* = m;
    }

    var out: [n][digest_len]u8 = undefined;
    var out_ptrs: [n]*[digest_len]u8 = undefined;
    for (&out_ptrs, &out) |*p, *o| p.* = o;

    H.hash(len, msg_ptrs, out_ptrs);

    for (msgs, out) |m, o| {
        var expected: [digest_len]u8 = undefined;
        StdHash.hash(&m, &expected, .{});
        try testing.expectEqualSlices(u8, &expected, &o);
    }
}

fn testSha3Variant(comptime ParHash: fn (comptime u16) type, comptime StdHash: type) !void {
    const rate = ParHash(1).block_bytes;
    inline for (.{ 1, 2, 3, 4, 8, native_parallelism }) |n| {
        inline for (.{ 0, 1, 32, rate - 1, rate, rate + 1, 2 * rate, 2 * rate + 13 }) |len| {
            try testSha3AgainstStd(ParHash, StdHash, n, len);
        }
    }
}

test "parallel SHA3-224 matches std" {
    try testSha3Variant(Sha3_224, std.crypto.hash.sha3.Sha3_224);
}

test "parallel SHA3-256 matches std" {
    try testSha3Variant(Sha3_256, std.crypto.hash.sha3.Sha3_256);
}

test "parallel SHA3-384 matches std" {
    try testSha3Variant(Sha3_384, std.crypto.hash.sha3.Sha3_384);
}

test "parallel SHA3-512 matches std" {
    try testSha3Variant(Sha3_512, std.crypto.hash.sha3.Sha3_512);
}
