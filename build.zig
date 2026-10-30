const std = @import("std");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0"))
        @panic("zig-process requires Zig 0.17.0");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .linux and target.result.os.tag != .windows) @panic("zig-process supports Linux and Windows");
    const mod = b.addModule("process", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    if (target.result.os.tag == .windows) {
        const fixture = b.addExecutable(.{ .name = "process-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/windows_fixture.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "process", .module = mod }} }) });
        const options = b.addOptions();
        options.addOptionPath("fixture", fixture.getEmittedBin());
        const tests_mod = b.createModule(.{ .root_source_file = b.path("tests/windows.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "process", .module = mod }} });
        tests_mod.addOptions("test_options", options);
        // Keep native platform failures diagnosable in ReleaseSafe as well.
        tests_mod.error_tracing = true;
        const tests = b.addTest(.{ .root_module = tests_mod });
        b.step("test", "Run native Windows file-backed process cases").dependOn(&b.addRunArtifact(tests).step);
        b.step("check", "Compile Windows process cases").dependOn(&tests.step);
        return;
    }
    const fixture = b.addExecutable(.{ .name = "process-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/fixture.zig"), .target = target, .optimize = optimize }) });
    fixture.root_module.addImport("process", mod);
    const options = b.addOptions();
    options.addOptionPath("fixture", fixture.getEmittedBin());
    options.addOption([]const u8, "workspace_root", std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, ".", b.allocator) catch @panic("workspace path unavailable"));
    const tests_mod = b.createModule(.{ .root_source_file = b.path("tests/process.zig"), .target = target, .optimize = optimize });
    tests_mod.addImport("process", mod);
    tests_mod.addOptions("test_options", options);
    const test_filter = b.option([]const u8, "test-filter", "Run matching tests");
    const tests = b.addTest(.{ .root_module = tests_mod, .filters = if (test_filter) |f| &.{f} else &.{} });
    const run_tests = b.addRunArtifact(tests);
    const report_tests_mod = b.createModule(.{ .root_source_file = b.path("src/run.zig"), .target = target, .optimize = optimize });
    report_tests_mod.addOptions("test_options", options);
    const report_tests = b.addTest(.{ .root_module = report_tests_mod, .filters = if (test_filter) |f| &.{f} else &.{} });
    const run_report_tests = b.addRunArtifact(report_tests);
    const test_step = b.step("test", "Run native process acceptance cases");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_report_tests.step);
    const check = b.step("check", "Compile tests and examples");
    check.dependOn(&tests.step);
    check.dependOn(&report_tests.step);
    inline for (.{ "capture", "poll", "lifecycle" }) |name| {
        const example = b.addExecutable(.{ .name = "process-" ++ name, .root_module = b.createModule(.{ .root_source_file = b.path("examples/" ++ name ++ ".zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "process", .module = mod }} }) });
        b.installArtifact(example);
        check.dependOn(&example.step);
        const run = b.addRunArtifact(example);
        if (comptime std.mem.eql(u8, name, "capture")) run.addArgs(&.{ "/bin/echo", "hello from zig-process" });
        b.step("run-" ++ name, "Run the " ++ name ++ " example").dependOn(&run.step);
    }
}
