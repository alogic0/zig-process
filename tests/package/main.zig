const std = @import("std");
const process = @import("process");
pub fn main(init: std.process.Init) !void {
    const result = try process.run(init.gpa, init.io, .{ .spawn = .{ .argv = &.{ "/bin/echo", "package-consumer" } } });
    defer result.deinit(init.gpa);
    if (!result.success() or !std.mem.eql(u8, result.stdout, "package-consumer\n")) return error.PackageConsumerFailed;
}
