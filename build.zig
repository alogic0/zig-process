const std = @import("std");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0"))
        @panic("zig-process requires Zig 0.17.0");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .linux) @panic("zig-process currently supports Linux only");
    const mod = b.addModule("process", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const fixture = b.addExecutable(.{ .name = "process-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/fixture.zig"), .target = target, .optimize = optimize }) });
    fixture.root_module.addImport("process", mod);
    const options = b.addOptions();
    options.addOptionPath("fixture", fixture.getEmittedBin());
    options.addOption([]const u8, "workspace_root", std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, ".", b.allocator) catch @panic("workspace path unavailable"));
    const tests_mod = b.createModule(.{ .root_source_file = b.path("tests/process.zig"), .target = target, .optimize = optimize });
    tests_mod.addImport("process", mod);
    tests_mod.addOptions("test_options", options);
    const tests = b.addTest(.{ .root_module = tests_mod, .filters = if (b.option([]const u8, "test-filter", "Run matching tests")) |f| &.{f} else &.{} });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run native process acceptance cases").dependOn(&run_tests.step);
    const check = b.step("check", "Compile tests and examples");
    check.dependOn(&tests.step);
    inline for (.{ "capture", "poll" }) |name| {
        const example = b.addExecutable(.{ .name = "process-" ++ name, .root_module = b.createModule(.{ .root_source_file = b.path("examples/" ++ name ++ ".zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "process", .module = mod }} }) });
        b.installArtifact(example);
        check.dependOn(&example.step);
        const run = b.addRunArtifact(example);
        if (comptime std.mem.eql(u8, name, "capture")) run.addArgs(&.{ "/bin/echo", "hello from zig-process" });
        b.step("run-" ++ name, "Run the " ++ name ++ " example").dependOn(&run.step);
    }
}
