const std = @import("std");
const builtin = @import("builtin");
const keccak = @import("keccak");
const bench_options = @import("bench_options");

const samples = 0x4001;
const permutations_per_sample = 8;
const is_x86_64 = builtin.target.cpu.arch == .x86_64;
const is_aarch64 = builtin.target.cpu.arch == .aarch64;
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

const round_constants = [24]u64{
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
};

/// 25 word positions, each containing four 64-bit instances.
const Buffer = [4][25]u64;
const Operation = *const fn (*align(32) Buffer) void;

const Case = struct {
    name: []const u8,
    instances: usize,
    op: Operation,
    sequential: bool = false,
};

fn toSequential(input: *const Buffer) Buffer {
    const source: *const [100]u64 = @ptrCast(input);
    var result: Buffer = undefined;
    const dest: *[100]u64 = @ptrCast(&result);
    for (0..4) |way| {
        for (0..25) |lane| dest[way * 25 + lane] = source[lane * 4 + way];
    }
    return result;
}

fn zigUnrolled(comptime unroll: u5) Operation {
    return struct {
        fn call(buf: *align(32) Buffer) void {
            const F = keccak.KeccakF1600Unrolled(4, unroll);
            const st: *F = @ptrCast(buf);
            for (0..permutations_per_sample) |_| st.permute();
        }
    }.call;
}

fn stdScalar(buf: *align(32) Buffer) void {
    const F = std.crypto.core.keccak.KeccakF(1600);
    const st: *F = @ptrCast(buf);
    for (0..permutations_per_sample) |_| st.permute();
}

fn dilithiumX4(buf: *align(32) Buffer) void {
    const st: *align(32) [25]@Vector(4, u64) = @ptrCast(buf);
    for (0..permutations_per_sample) |_| pqcrystals_dilithium_fips202x4_avx2_f1600x4(st, &round_constants);
}

fn nativeX1(buf: *align(32) Buffer) void {
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

fn nativeX4(buf: *align(32) Buffer) void {
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

fn validate(cases: []const Case) !void {
    var input: Buffer align(32) = undefined;
    var ascon = std.Random.Ascon.init(@splat(1));
    ascon.random().bytes(std.mem.asBytes(&input));

    const in_flat: *const [4 * 25]u64 = @ptrCast(&input);
    var expected: Buffer align(32) = undefined;
    for (0..4) |k| {
        var scalar: Buffer align(32) = undefined;
        for (0..25) |i| scalar[0][i] = in_flat[i * 4 + k];
        stdScalar(&scalar);
        const flat: *[4 * 25]u64 = @ptrCast(&expected);
        for (0..25) |i| flat[i * 4 + k] = scalar[0][i];
    }
    const expected_sequential = toSequential(&expected);

    for (cases) |case| {
        var actual: Buffer align(32) = if (case.sequential) toSequential(&input) else input;
        case.op(&actual);
        if (case.instances == 1) {
            if (!std.mem.eql(u8, std.mem.asBytes(&expected_sequential[0]), std.mem.asBytes(&actual[0]))) {
                std.log.err("{s}: Keccak mismatch", .{case.name});
                return error.KeccakMismatch;
            }
            continue;
        }
        if (case.instances != 4) continue;
        const reference = if (case.sequential) &expected_sequential else &expected;
        if (!std.mem.eql(u8, std.mem.asBytes(reference), std.mem.asBytes(&actual))) {
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

fn measure(op: Operation, buf: *align(32) Buffer) u64 {
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
    const variants = [_]Case{
        .{ .name = "Zig 4-way unroll 1", .instances = 4, .op = zigUnrolled(1) },
        .{ .name = "Zig 4-way unroll 4", .instances = 4, .op = zigUnrolled(4) },
    };
    const dilithium_cases = if (bench_options.dilithium_avx2 and is_x86_64) [_]Case{
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

    const cases = [_]Case{
        .{ .name = "std KeccakF(1600) scalar", .instances = 1, .op = stdScalar, .sequential = true },
    } ++ variants ++ dilithium_cases ++ native_cases;

    if (!bench_options.dilithium_avx2) {
        std.debug.print("Dilithium AVX2 reference disabled; pass -Ddilithium-avx2-dir=<path> to include it.\n", .{});
    } else if (!is_x86_64) {
        std.debug.print("Dilithium AVX2 reference skipped on {s} (x86_64 only).\n", .{@tagName(builtin.target.cpu.arch)});
    }
    if (!bench_options.mldsa_native)
        std.debug.print("ML-DSA native reference disabled; pass -Dmldsa-native-dir=<path> to include it.\n", .{});
    std.debug.print("native_parallelism = {d}; comparing four-way unroll 1 and 4\n", .{keccak.native_parallelism});

    try validate(&cases);

    var buf: [cases.len]Buffer align(32) = undefined;
    var seed: Buffer align(32) = undefined;
    var ascon = std.Random.Ascon.init(@splat(0));
    ascon.random().bytes(std.mem.asBytes(&seed));
    for (cases, &buf) |case, *state| {
        state.* = if (case.sequential) toSequential(&seed) else seed;
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
        std.debug.print("{s:<26}: {d:>8.1} cycles/call, {d:>7.1} cycles/instance\n", .{
            case.name,
            per_call,
            per_call / @as(f64, @floatFromInt(case.instances)),
        });
    }
    var checksum: u64 = 0;
    for (&buf) |*state| checksum ^= state[0][0];
    std.debug.print("checksum: {x}\n", .{checksum});
}
