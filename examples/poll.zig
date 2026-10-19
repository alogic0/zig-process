const std = @import("std");
const process = @import("process");

pub fn main(init: std.process.Init) !void {
    var child = try process.Child.spawn(init.gpa, init.io, .{ .argv = &.{ "/bin/sleep", "0.05" } });
    defer child.deinit();
    while (try child.poll() == null) {
        // A desktop host can do other work here or poll child.pollHandle().
        try init.io.sleep(.fromMilliseconds(5), .awake);
    }
    std.debug.print("{f}\n", .{try child.finish()});
}
