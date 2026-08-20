const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const awp_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench_exe = b.addExecutable(.{
        .name = "bench_dispatch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_dispatch.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "awp", .module = awp_mod },
            },
        }),
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the Zig dispatch benchmark");
    bench_step.dependOn(&run_bench.step);
}
