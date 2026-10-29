const std = @import("std");
const builtin = @import("builtin");
const keccak = @import("keccak");
const bench_options = @import("bench_options");

const samples = 0x4001;
const permutations_per_sample = 8;
const is_x86_64 = builtin.target.cpu.arch == .x86_64;
const is_aarch64 = builtin.target.cpu.arch == .aarch64;
const has_avx512f = is_x86_64 and std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx512f);
const has_arm_sha3 = is_aarch64 and std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .sha3);

extern fn pqcrystals_dilithium_fips202x4_avx2_f1600x4(state: *align(32) [25]@Vector(4, u64), rc: *const [24]u64) callconv(.c) void;
extern fn PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x4_avx2_asm(
    state: *align(32) [100]u64,
    rc: *const [24]u64,
    rho8: *const [4]u64,
    rho56: *const [4]u64,
) callconv(.c) void;
extern const PQCP_MLDSA_NATIVE_MLDSA44_keccak_rho8: [4]u64;
extern const PQCP_MLDSA_NATIVE_MLDSA44_keccak_rho56: [4]u64;
extern const PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_round_constants: [24]u64;

extern fn PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x1_scalar_aarch64_asm(
    state: *[25]u64,
    rc: *const [24]u64,
) callconv(.c) void;
extern fn PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x1_v84a_aarch64_asm(
    state: *[25]u64,
    rc: *const [24]u64,
) callconv(.c) void;
extern fn PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x2_v84a_aarch64_asm(
    state: *[50]u64,
    rc: *const [24]u64,
) callconv(.c) void;
extern fn PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x4_v8a_scalar_hybrid_aarch64_asm(
    state: *align(32) [100]u64,
    rc: *const [24]u64,
) callconv(.c) void;
extern fn PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x4_v8a_v84a_scalar_hybrid_aarch64_asm(
    state: *align(32) [100]u64,
    rc: *const [24]u64,
) callconv(.c) void;

extern fn PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_permute(state: *[25]u64) callconv(.c) void;
extern fn PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600x4_permute(state: *align(32) [100]u64) callconv(.c) void;

extern fn KeccakP1600_AVX2_OverwriteBytes(state: *anyopaque, data: [*]const u8, offset: c_uint, length: c_uint) callconv(.c) void;
extern fn KeccakP1600_AVX2_ExtractBytes(state: *const anyopaque, data: [*]u8, offset: c_uint, length: c_uint) callconv(.c) void;
extern fn KeccakP1600_AVX2_Permute_24rounds(state: *anyopaque) callconv(.c) void;
extern fn KeccakP1600times2_SSSE3_PermuteAll_24rounds(states: *anyopaque) callconv(.c) void;
extern fn KeccakP1600times4_AVX2_PermuteAll_24rounds(states: *anyopaque) callconv(.c) void;
extern fn KeccakP1600_AVX512_Permute_24rounds(state: *anyopaque) callconv(.c) void;
extern fn KeccakP1600times2_AVX512_PermuteAll_24rounds(states: *anyopaque) callconv(.c) void;
extern fn KeccakP1600times4_AVX512_PermuteAll_24rounds(states: *anyopaque) callconv(.c) void;
extern fn KeccakP1600times8_AVX512_PermuteAll_24rounds(states: *anyopaque) callconv(.c) void;

extern fn KeccakP1600_plain64_Permute_24rounds(state: *anyopaque) callconv(.c) void;
extern fn KeccakP1600_v84a_Permute_24rounds(state: *anyopaque) callconv(.c) void;
extern fn KeccakP1600times2_PermuteAll_24rounds(states: *anyopaque) callconv(.c) void;
extern fn KeccakP1600times4_PermuteAll_24rounds(states: *anyopaque) callconv(.c) void;

const round_constants = [24]u64{
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
};

const max_instances: usize = @max(8, keccak.native_parallelism);
const Buffer = [max_instances][25]u64;
const Operation = *const fn (*align(64) Buffer) void;

const Case = struct {
    name: []const u8,
    instances: usize,
    op: Operation,
    sequential: bool = false,
    xkcp_avx2_1way: bool = false,
};

/// Convert from sequential `[instances][25]u64` layout to word-sliced `[25][instances]u64` layout
/// for the first `instances` instances.
fn toSliced(input: *const Buffer, instances: usize) Buffer {
    var result: Buffer = @splat(@splat(0));
    const dest: *[max_instances * 25]u64 = @ptrCast(&result);
    for (0..25) |word| {
        for (0..instances) |way| {
            dest[word * instances + way] = input[way][word];
        }
    }
    return result;
}

fn zigUnrolled(comptime n: u16, comptime unroll: u5) Operation {
    return struct {
        fn call(buf: *align(64) Buffer) void {
            const F = keccak.KeccakF1600Unrolled(n, unroll);
            const st: *F = @ptrCast(buf);
            for (0..permutations_per_sample) |_| st.permute();
        }
    }.call;
}

fn stdScalar(buf: *align(64) Buffer) void {
    const F = std.crypto.core.keccak.KeccakF(1600);
    const st: *F = @ptrCast(&buf[0]);
    for (0..permutations_per_sample) |_| st.permute();
}

fn dilithiumX4(buf: *align(64) Buffer) void {
    const st: *align(32) [25]@Vector(4, u64) = @ptrCast(buf);
    for (0..permutations_per_sample) |_| pqcrystals_dilithium_fips202x4_avx2_f1600x4(st, &round_constants);
}

fn nativeX1(buf: *align(64) Buffer) void {
    const st: *[25]u64 = @ptrCast(&buf[0]);
    for (0..permutations_per_sample) |_| {
        switch (comptime builtin.target.cpu.arch) {
            .aarch64 => {
                if (comptime has_arm_sha3) {
                    PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x1_v84a_aarch64_asm(
                        st,
                        &PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_round_constants,
                    );
                } else {
                    PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x1_scalar_aarch64_asm(
                        st,
                        &PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_round_constants,
                    );
                }
            },
            else => PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_permute(st),
        }
    }
}

fn nativeX4(buf: *align(64) Buffer) void {
    const st: *align(32) [100]u64 = @ptrCast(buf);
    for (0..permutations_per_sample) |_| {
        switch (comptime builtin.target.cpu.arch) {
            .x86_64 => PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x4_avx2_asm(
                st,
                &PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_round_constants,
                &PQCP_MLDSA_NATIVE_MLDSA44_keccak_rho8,
                &PQCP_MLDSA_NATIVE_MLDSA44_keccak_rho56,
            ),
            .aarch64 => {
                if (comptime has_arm_sha3 and builtin.target.os.tag.isDarwin()) {
                    PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x2_v84a_aarch64_asm(
                        st[0..50],
                        &PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_round_constants,
                    );
                    PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x2_v84a_aarch64_asm(
                        st[50..100],
                        &PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_round_constants,
                    );
                } else if (comptime has_arm_sha3) {
                    PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x4_v8a_v84a_scalar_hybrid_aarch64_asm(
                        st,
                        &PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_round_constants,
                    );
                } else {
                    PQCP_MLDSA_NATIVE_MLDSA44_keccak_f1600_x4_v8a_scalar_hybrid_aarch64_asm(
                        st,
                        &PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600_round_constants,
                    );
                }
            },
            else => PQCP_MLDSA_NATIVE_MLDSA44_keccakf1600x4_permute(st),
        }
    }
}

fn xkcpAvx2X1(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600_AVX2_Permute_24rounds(&buf[0]);
}

fn xkcpSsse3X2(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600times2_SSSE3_PermuteAll_24rounds(buf);
}

fn xkcpAvx2X4(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600times4_AVX2_PermuteAll_24rounds(buf);
}

fn xkcpAvx512X1(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600_AVX512_Permute_24rounds(&buf[0]);
}

fn xkcpAvx512X2(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600times2_AVX512_PermuteAll_24rounds(buf);
}

fn xkcpAvx512X4(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600times4_AVX512_PermuteAll_24rounds(buf);
}

fn xkcpAvx512X8(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600times8_AVX512_PermuteAll_24rounds(buf);
}

fn xkcpPlain64X1(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600_plain64_Permute_24rounds(&buf[0]);
}

fn xkcpArmv84aSha3X1(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600_v84a_Permute_24rounds(&buf[0]);
}

fn xkcpArmv8aX2(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600times2_PermuteAll_24rounds(buf);
}

fn xkcpArmv8aX4(buf: *align(64) Buffer) void {
    for (0..permutations_per_sample) |_| KeccakP1600times4_PermuteAll_24rounds(buf);
}

fn prepareState(case: Case, input_seq: *const Buffer) Buffer {
    if (comptime is_x86_64 and bench_options.xkcp) {
        if (case.xkcp_avx2_1way) {
            var state: Buffer = @splat(@splat(0));
            KeccakP1600_AVX2_OverwriteBytes(&state[0], @ptrCast(&input_seq[0]), 0, 200);
            return state;
        }
    }
    return if (case.sequential) input_seq.* else toSliced(input_seq, case.instances);
}

fn validate(cases: []const Case) !void {
    var input_seq: Buffer align(64) = undefined;
    var ascon = std.Random.Ascon.init(@splat(1));
    ascon.random().bytes(std.mem.asBytes(&input_seq));

    var expected_seq: Buffer align(64) = undefined;
    for (0..max_instances) |k| {
        var scalar: Buffer align(64) = @splat(@splat(0));
        scalar[0] = input_seq[k];
        stdScalar(&scalar);
        expected_seq[k] = scalar[0];
    }

    for (cases) |case| {
        var actual: Buffer align(64) = prepareState(case, &input_seq);
        case.op(&actual);
        if (comptime is_x86_64 and bench_options.xkcp) {
            if (case.xkcp_avx2_1way) {
                var extracted: [200]u8 = undefined;
                KeccakP1600_AVX2_ExtractBytes(&actual[0], &extracted, 0, 200);
                if (!std.mem.eql(u8, std.mem.asBytes(&expected_seq[0]), &extracted)) {
                    std.log.err("{s}: Keccak mismatch", .{case.name});
                    return error.KeccakMismatch;
                }
                continue;
            }
        }
        const reference: Buffer = if (case.sequential) expected_seq else toSliced(&expected_seq, case.instances);
        const byte_len = case.instances * 25 * @sizeOf(u64);
        if (!std.mem.eql(u8, std.mem.asBytes(&reference)[0..byte_len], std.mem.asBytes(&actual)[0..byte_len])) {
            std.log.err("{s}: Keccak mismatch", .{case.name});
            return error.KeccakMismatch;
        }
    }
}

inline fn cycles() u64 {
    return switch (comptime builtin.target.cpu.arch) {
        .x86, .x86_64 => asm volatile (
            \\rdtsc
            \\shl $32, %%rdx
            \\or %%rdx, %%rax
            : [ret] "={rax}" (-> u64),
            :
            : .{ .rdx = true, .rax = true }),
        .aarch64, .aarch64_be => asm volatile (
            \\mrs %[ret], cntvct_el0
            : [ret] "=r" (-> u64),
        ),
        .riscv64 => asm volatile (
            \\rdcycle %[ret]
            : [ret] "=r" (-> u64),
        ),
        .riscv32 => blk: {
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            asm volatile (
                \\rdcycleh %[hi]
                \\rdcycle %[lo]
                : [lo] "=r" (lo),
                  [hi] "=r" (hi),
            );
            break :blk (@as(u64, hi) << 32) | lo;
        },
        else => @compileError("unsupported architecture for cycle counter"),
    };
}

inline fn fence() void {
    switch (comptime builtin.target.cpu.arch) {
        .x86, .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64, .aarch64_be => asm volatile (
            \\dsb sy
            \\isb
            ::: .{ .memory = true }),
        .riscv32, .riscv64 => asm volatile ("fence rw, rw" ::: .{ .memory = true }),
        else => @compileError("unsupported architecture for fence"),
    }
}

fn measure(op: Operation, buf: *align(64) Buffer) u64 {
    fence();
    const start = cycles();
    fence();
    op(buf);
    fence();
    const end = cycles();
    fence();
    return end - start;
}

pub fn main(init: std.process.Init) !void {
    const nat = keccak.native_parallelism;
    const variants = [_]Case{
        .{ .name = "Zig 1-way unroll 1", .instances = 1, .op = zigUnrolled(1, 1) },
        .{ .name = "Zig 1-way unroll 2", .instances = 1, .op = zigUnrolled(1, 2) },
        .{ .name = "Zig 1-way unroll 4", .instances = 1, .op = zigUnrolled(1, 4) },
        .{ .name = "Zig 2-way unroll 1", .instances = 2, .op = zigUnrolled(2, 1) },
        .{ .name = "Zig 2-way unroll 2", .instances = 2, .op = zigUnrolled(2, 2) },
        .{ .name = "Zig 2-way unroll 4", .instances = 2, .op = zigUnrolled(2, 4) },
        .{ .name = "Zig 4-way unroll 1", .instances = 4, .op = zigUnrolled(4, 1) },
        .{ .name = "Zig 4-way unroll 2", .instances = 4, .op = zigUnrolled(4, 2) },
        .{ .name = "Zig 4-way unroll 4", .instances = 4, .op = zigUnrolled(4, 4) },
        .{ .name = "Zig 8-way unroll 1", .instances = 8, .op = zigUnrolled(8, 1) },
        .{ .name = "Zig 8-way unroll 2", .instances = 8, .op = zigUnrolled(8, 2) },
        .{ .name = "Zig 8-way unroll 4", .instances = 8, .op = zigUnrolled(8, 4) },
        .{
            .name = std.fmt.comptimePrint("Zig native ({d}-way) unroll 1", .{nat}),
            .instances = nat,
            .op = zigUnrolled(nat, 1),
        },
        .{
            .name = std.fmt.comptimePrint("Zig native ({d}-way) unroll 2", .{nat}),
            .instances = nat,
            .op = zigUnrolled(nat, 2),
        },
        .{
            .name = std.fmt.comptimePrint("Zig native ({d}-way) unroll 4", .{nat}),
            .instances = nat,
            .op = zigUnrolled(nat, 4),
        },
    };
    const dilithium_cases = if (bench_options.dilithium and is_x86_64) [_]Case{
        .{ .name = "Dilithium f1600x4.S", .instances = 4, .op = dilithiumX4 },
    } else [_]Case{};
    const native_cases = if (bench_options.mldsa_native) switch (comptime builtin.target.cpu.arch) {
        .x86_64 => [_]Case{
            .{ .name = "ML-DSA native Keccak x4", .instances = 4, .op = nativeX4, .sequential = true },
        },
        .aarch64 => [_]Case{
            .{ .name = "ML-DSA native Keccak x1", .instances = 1, .op = nativeX1, .sequential = true },
            .{ .name = "ML-DSA native Keccak x4", .instances = 4, .op = nativeX4, .sequential = true },
        },
        else => [_]Case{
            .{ .name = "ML-DSA Keccak x1", .instances = 1, .op = nativeX1, .sequential = true },
            .{ .name = "ML-DSA Keccak x4", .instances = 4, .op = nativeX4, .sequential = true },
        },
    } else [_]Case{};

    const xkcp_cases = if (bench_options.xkcp) switch (comptime builtin.target.cpu.arch) {
        .x86_64 => [_]Case{
            .{ .name = "XKCP AVX2 x1", .instances = 1, .op = xkcpAvx2X1, .sequential = true, .xkcp_avx2_1way = true },
            .{ .name = "XKCP SIMD128 (SSSE3) x2", .instances = 2, .op = xkcpSsse3X2 },
            .{ .name = "XKCP AVX2 x4", .instances = 4, .op = xkcpAvx2X4 },
        } ++ (if (has_avx512f) [_]Case{
            .{ .name = "XKCP AVX512 x1", .instances = 1, .op = xkcpAvx512X1, .sequential = true },
            .{ .name = "XKCP AVX512 x2", .instances = 2, .op = xkcpAvx512X2 },
            .{ .name = "XKCP AVX512 x4", .instances = 4, .op = xkcpAvx512X4 },
            .{ .name = "XKCP AVX512 x8", .instances = 8, .op = xkcpAvx512X8 },
        } else [_]Case{}),
        .aarch64 => [_]Case{
            .{ .name = "XKCP plain64 x1", .instances = 1, .op = xkcpPlain64X1, .sequential = true },
        } ++ (if (has_arm_sha3) [_]Case{
            .{ .name = "XKCP ARMv8.4A SHA3 x1", .instances = 1, .op = xkcpArmv84aSha3X1, .sequential = true },
        } else [_]Case{}) ++ [_]Case{
            .{ .name = if (has_arm_sha3) "XKCP ARMv8.4A SHA3 x2" else "XKCP ARMv8A NEON x2", .instances = 2, .op = xkcpArmv8aX2 },
            .{ .name = if (has_arm_sha3) "XKCP ARMv8.4A SHA3 x4" else "XKCP ARMv8A NEON x4", .instances = 4, .op = xkcpArmv8aX4, .sequential = true },
        },
        else => [_]Case{
            .{ .name = "XKCP plain64 x1", .instances = 1, .op = xkcpPlain64X1, .sequential = true },
        },
    } else [_]Case{};

    const cases = [_]Case{
        .{ .name = "std KeccakF(1600) scalar", .instances = 1, .op = stdScalar, .sequential = true },
    } ++ variants ++ dilithium_cases ++ native_cases ++ xkcp_cases;

    if (!bench_options.dilithium) {
        std.debug.print("Dilithium AVX2 reference disabled; pass -Ddilithium-dir=<path> to include it.\n", .{});
    } else if (!is_x86_64) {
        std.debug.print("Dilithium AVX2 reference skipped on {s} (x86_64 only).\n", .{@tagName(builtin.target.cpu.arch)});
    }
    if (!bench_options.mldsa_native)
        std.debug.print("ML-DSA native reference disabled; pass -Dmldsa-native-dir=<path> to include it.\n", .{});
    if (!bench_options.xkcp)
        std.debug.print("XKCP reference disabled; pass -Dxkcp-dir=<path> to include it.\n", .{});
    std.debug.print("native_parallelism = {d}; comparing 1/2/4/8-way and native ({d}-way) permutations\n", .{ nat, nat });

    try validate(&cases);

    var buf: [cases.len]Buffer align(64) = undefined;
    var seed: Buffer align(64) = undefined;
    var ascon = std.Random.Ascon.init(@splat(0));
    ascon.random().bytes(std.mem.asBytes(&seed));
    for (cases, &buf) |case, *state| {
        state.* = prepareState(case, &seed);
        case.op(state);
    }

    const all_times = try init.gpa.alloc([samples]u64, cases.len);
    defer init.gpa.free(all_times);
    for (0..samples) |sample| {
        for (0..cases.len) |offset| {
            const index = (sample + offset) % cases.len;
            all_times[index][sample] = measure(cases[index].op, &buf[index]);
        }
    }
    for (cases, all_times) |case, *times| {
        std.sort.block(u64, times, {}, std.sort.asc(u64));
        const median_cycles = times.*[samples / 2];
        const median: f64 = @floatFromInt(median_cycles);
        const per_call = median / permutations_per_sample;
        std.debug.print("{s:<28}: {d:>8.1} cycles/call, {d:>7.1} cycles/instance\n", .{
            case.name,
            per_call,
            per_call / @as(f64, @floatFromInt(case.instances)),
        });
    }
    var checksum: u64 = 0;
    for (&buf, 0..) |*state, i| checksum ^= std.math.rotl(u64, state[0][0], i);
    std.debug.print("checksum: {x}\n", .{checksum});
}
