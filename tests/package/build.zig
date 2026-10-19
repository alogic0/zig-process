const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("process", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "package-consumer", .root_module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize }) });
    exe.root_module.addImport("process", dependency.module("process"));
    b.step("test", "Run package dependency smoke check").dependOn(&b.addRunArtifact(exe).step);
}
