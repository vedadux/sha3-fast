const std = @import("std");

fn addBenchmark(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const benchmark = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        }),
    });

    const install = b.addInstallArtifact(benchmark, .{});
    b.getInstallStep().dependOn(&install.step);
    const step = b.step(name, b.fmt("Build the {s} benchmark", .{name}));
    step.dependOn(&install.step);
    return benchmark;
}

fn addDilithiumDependency(
    b: *std.Build,
    benchmark: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    dir: []const u8,
) void {
    if (target.result.cpu.arch != .x86_64) return;

    const avx2_dir = b.fmt("{s}/avx2", .{dir});
    benchmark.root_module.addCSourceFiles(.{
        .root = .{ .cwd_relative = avx2_dir },
        .files = &.{"f1600x4.S"},
        .flags = &.{ "-mavx2", b.fmt("-Wa,-I,{s}", .{avx2_dir}) },
    });
    benchmark.root_module.addIncludePath(.{ .cwd_relative = avx2_dir });
}

fn addMldsaNativeDependency(
    b: *std.Build,
    benchmark: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dir: []const u8,
) void {
    const is_x86_64 = target.result.cpu.arch == .x86_64;
    const is_aarch64 = target.result.cpu.arch == .aarch64;

    const native_src = b.fmt("{s}/mldsa", .{dir});
    const native = b.addLibrary(.{
        .name = "mldsa_native_bench",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    native.root_module.link_libc = true;
    native.root_module.addIncludePath(.{ .cwd_relative = native_src });

    if (is_x86_64) {
        native.root_module.addCSourceFiles(.{
            .root = .{ .cwd_relative = native_src },
            .files = &.{
                "mldsa_native_asm.S",
                "src/fips202/native/x86_64/src/keccakf1600_constants.c",
            },
            .flags = &.{
                "-mavx2",
                "-DMLD_CONFIG_USE_NATIVE_BACKEND_FIPS202",
            },
        });
    } else if (is_aarch64) {
        native.root_module.addCSourceFiles(.{
            .root = .{ .cwd_relative = native_src },
            .files = &.{
                "src/fips202/keccakf1600.c",
                "src/fips202/native/aarch64/src/keccakf1600_round_constants.c",
                "src/fips202/native/aarch64/src/keccak_f1600_x1_scalar_aarch64_asm.S",
                "src/fips202/native/aarch64/src/keccak_f1600_x1_v84a_aarch64_asm.S",
                "src/fips202/native/aarch64/src/keccak_f1600_x2_v84a_aarch64_asm.S",
                "src/fips202/native/aarch64/src/keccak_f1600_x4_v8a_scalar_hybrid_aarch64_asm.S",
                "src/fips202/native/aarch64/src/keccak_f1600_x4_v8a_v84a_scalar_hybrid_aarch64_asm.S",
            },
            .flags = &.{
                "-O3",
                "-DMLD_CONFIG_USE_NATIVE_BACKEND_FIPS202",
                "-DMLD_FIPS202_AARCH64_NEED_X1_SCALAR",
                "-DMLD_FIPS202_AARCH64_NEED_X1_V84A",
                "-DMLD_FIPS202_AARCH64_NEED_X2_V84A",
                "-DMLD_FIPS202_AARCH64_NEED_X4_V8A_SCALAR_HYBRID",
                "-DMLD_FIPS202_AARCH64_NEED_X4_V8A_V84A_SCALAR_HYBRID",
            },
        });
    } else {
        native.root_module.addCSourceFiles(.{
            .root = .{ .cwd_relative = native_src },
            .files = &.{
                "src/fips202/keccakf1600.c",
            },
            .flags = &.{"-O3"},
        });
    }

    benchmark.root_module.linkLibrary(native);
    benchmark.root_module.link_libc = true;
}

fn addXkcpDependency(
    b: *std.Build,
    benchmark: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dir: []const u8,
) void {
    const is_x86_64 = target.result.cpu.arch == .x86_64;
    const is_aarch64 = target.result.cpu.arch == .aarch64;
    const has_avx512f = is_x86_64 and std.Target.x86.featureSetHas(target.result.cpu.features, .avx512f);
    const has_arm_sha3 = is_aarch64 and std.Target.aarch64.featureSetHas(target.result.cpu.features, .sha3);

    const xkcp_config = b.addWriteFiles();
    _ = xkcp_config.add("config.h", "/* empty XKCP config.h */\n");

    const xkcp = b.addLibrary(.{
        .name = "xkcp_bench",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    xkcp.root_module.link_libc = true;
    xkcp.root_module.addIncludePath(xkcp_config.getDirectory());
    xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/common", .{dir}) });
    xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/common", .{dir}) });
    xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600/common", .{dir}) });
    xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600/plain-64bits", .{dir}) });
    xkcp.root_module.addCMacro("KeccakP1600_excluded", "1");

    if (is_x86_64) {
        xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600-times2/SIMD128", .{dir}) });
        xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600-times4/AVX2", .{dir}) });
        xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600-times4/AVX2/SnP", .{dir}) });
        xkcp.root_module.addCSourceFiles(.{
            .root = .{ .cwd_relative = dir },
            .files = &.{
                "lib/low/KeccakP-1600/AVX2/KeccakP-1600-AVX2.s",
                "lib/low/KeccakP-1600-times2/SIMD128/KeccakP-1600-times2-SIMD128.c",
                "lib/low/KeccakP-1600-times4/AVX2/KeccakP-1600-times4-AVX2.c",
            },
            .flags = &.{ "-O3", "-mavx2" },
        });
        if (has_avx512f) {
            xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600/AVX512", .{dir}) });
            xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600-times2/AVX512", .{dir}) });
            xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600-times4/AVX512", .{dir}) });
            xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600-times8/AVX512", .{dir}) });
            xkcp.root_module.addCSourceFiles(.{
                .root = .{ .cwd_relative = dir },
                .files = &.{
                    "lib/low/KeccakP-1600/AVX512/KeccakP-1600-AVX512.s",
                    "lib/low/KeccakP-1600-times2/AVX512/KeccakP-1600-times2-AVX512.c",
                    "lib/low/KeccakP-1600-times4/AVX512/KeccakP-1600-times4-AVX512.c",
                    "lib/low/KeccakP-1600-times8/AVX512/KeccakP-1600-times8-AVX512.c",
                },
                .flags = &.{ "-O3", "-mavx512f", "-mavx512vl" },
            });
        }
    } else if (is_aarch64) {
        xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600/plain-64bits/SnP", .{dir}) });
        xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600/ARMv8A-SHA3", .{dir}) });
        xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600-times2/ARMv8A", .{dir}) });
        xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600-times4/ARMv8A", .{dir}) });
        const xkcp_aarch64_wrappers = b.addWriteFiles();
        _ = xkcp_aarch64_wrappers.add("xkcp_aarch64_asm.S",
            \\#include "KeccakP-1600-x1-v84a-asm.s"
            \\#include "KeccakP-1600-inplace-pl2-armv8a-neon.s"
            \\#include "KeccakP-1600-times2-x2-v84a-asm.s"
            \\#include "KeccakP-1600-times4-x4-v8a-asm.s"
            \\#include "KeccakP-1600-times4-x4-v84a-asm.s"
            \\
        );
        const arm_flags: []const []const u8 = if (has_arm_sha3)
            &.{ "-O3", "-march=armv8.2-a+sha3" }
        else
            &.{ "-O3", "-march=armv8.2-a" };
        xkcp.root_module.addCSourceFile(.{
            .file = xkcp_aarch64_wrappers.getDirectory().path(b, "xkcp_aarch64_asm.S"),
            .flags = arm_flags,
        });
        const arm_c_files: []const []const u8 = if (has_arm_sha3)
            &.{
                "lib/low/KeccakP-1600/plain-64bits/KeccakP-1600-opt64.c",
                "lib/low/KeccakP-1600/ARMv8A-SHA3/KeccakP-1600-x1-v84a.c",
                "lib/low/KeccakP-1600-times4/ARMv8A/KeccakP-1600-times4-armv8a.c",
            }
        else
            &.{
                "lib/low/KeccakP-1600/plain-64bits/KeccakP-1600-opt64.c",
                "lib/low/KeccakP-1600-times4/ARMv8A/KeccakP-1600-times4-armv8a.c",
            };
        xkcp.root_module.addCSourceFiles(.{
            .root = .{ .cwd_relative = dir },
            .files = arm_c_files,
            .flags = arm_flags,
        });
    } else {
        xkcp.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/lib/low/KeccakP-1600/plain-64bits/SnP", .{dir}) });
        xkcp.root_module.addCSourceFiles(.{
            .root = .{ .cwd_relative = dir },
            .files = &.{
                "lib/low/KeccakP-1600/plain-64bits/KeccakP-1600-opt64.c",
            },
            .flags = &.{"-O3"},
        });
    }

    benchmark.root_module.linkLibrary(xkcp);
    benchmark.root_module.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("sha3_fast", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sha3_fast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sha3_fast", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const keccak_bench = addBenchmark(b, "bench-keccak", "src/bench.zig", target, optimize);
    keccak_bench.root_module.addImport("keccak", b.createModule(.{
        .root_source_file = b.path("src/keccak.zig"),
        .target = target,
        .optimize = optimize,
    }));
    keccak_bench.root_module.addImport("sha3_fast", mod);

    const dilithium_dir = b.option([]const u8, "dilithium-dir", "Path to the Dilithium repository");
    const mldsa_native_dir = b.option([]const u8, "mldsa-native-dir", "Path to the mldsa-native repository");
    const xkcp_dir = b.option([]const u8, "xkcp-dir", "Path to the XKCP repository");

    const bench_options = b.addOptions();
    bench_options.addOption(bool, "dilithium", dilithium_dir != null and target.result.cpu.arch == .x86_64);
    bench_options.addOption(bool, "mldsa_native", mldsa_native_dir != null);
    bench_options.addOption(bool, "xkcp", xkcp_dir != null);
    keccak_bench.root_module.addOptions("bench_options", bench_options);

    if (dilithium_dir) |dir| addDilithiumDependency(b, keccak_bench, target, dir);
    if (mldsa_native_dir) |dir| addMldsaNativeDependency(b, keccak_bench, target, optimize, dir);
    if (xkcp_dir) |dir| addXkcpDependency(b, keccak_bench, target, optimize, dir);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}


