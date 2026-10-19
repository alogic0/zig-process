const std = @import("std");
const process = @import("process");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.ExpectedCommand;
    const result = try process.run(init.gpa, init.io, .{ .spawn = .{ .argv = args[1..], .search_path = true } });
    defer result.deinit(init.gpa);
    try std.Io.File.stdout().writeStreamingAll(init.io, result.stdout);
    try std.Io.File.stderr().writeStreamingAll(init.io, result.stderr);
    std.debug.print("outcome={s}, term={f}\n", .{ @tagName(result.outcome), result.term });
}
