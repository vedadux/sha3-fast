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

    const is_x86_64 = target.result.cpu.arch == .x86_64;
    const is_aarch64 = target.result.cpu.arch == .aarch64;

    const dilithium_dir = b.option([]const u8, "dilithium-avx2-dir", "Path to Dilithium AVX2 sources (f1600x4.S, x86_64 only)");
    const mldsa_native_dir = b.option([]const u8, "mldsa-native-dir", "Path to the mldsa-native repository");
    const bench_options = b.addOptions();
    bench_options.addOption(bool, "dilithium_avx2", dilithium_dir != null and is_x86_64);
    bench_options.addOption(bool, "mldsa_native", mldsa_native_dir != null);
    keccak_bench.root_module.addOptions("bench_options", bench_options);

    if (mldsa_native_dir) |dir| {
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
        keccak_bench.root_module.linkLibrary(native);
        keccak_bench.root_module.link_libc = true;
    }

    if (dilithium_dir) |dir| {
        if (is_x86_64) {
            keccak_bench.root_module.addCSourceFiles(.{
                .root = .{ .cwd_relative = dir },
                .files = &.{"f1600x4.S"},
                .flags = &.{ "-mavx2", b.fmt("-Wa,-I,{s}", .{dir}) },
            });
            keccak_bench.root_module.addIncludePath(.{ .cwd_relative = dir });
        }
    }

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

