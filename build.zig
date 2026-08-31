const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hypertask",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run hypertask");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const output_parity_test_step = b.step("output-parity-test", "Run golden-file HTTP stub tests");
    const python = b.option([]const u8, "python", "Python 3 executable for HTTP stub tests") orelse
        b.findProgram(&.{ "python3", "python" }, &.{}) catch "python3";
    const output_parity_tests = b.addSystemCommand(&.{ python, "scripts/output_parity_test.py" });
    output_parity_tests.addArtifactArg(exe);
    output_parity_test_step.dependOn(&output_parity_tests.step);
    test_step.dependOn(&output_parity_tests.step);
}
