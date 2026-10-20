//! Backend-style log redirection, bounded status and explicit final cleanup.
const std = @import("std");
const process = @import("process");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var random: [12]u8 = undefined;
    io.random(&random);
    const path = try init.arena.allocator().print("/tmp/process-lifecycle-{s}.log", .{std.fmt.bytesToHex(random, .lower)});
    const log = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer log.close(io);

    // One budget covers launch and observation. Logs and application resources
    // remain caller-owned; only Child owns the process and its group.
    const end = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    var child = try process.Child.spawnUntil(init.gpa, io, .{
        .argv = &.{ "/bin/echo", "backend-style lifecycle" },
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    }, end);
    defer child.deinit();
    const pid = child.pid.?;
    const observed = try child.pollUntil(end, null) orelse return error.ExitDeadline;
    if (!observed.success() or child.pid != pid) return error.InvalidObservation;
    // The owner still reserves the PID here. A backend may inspect its owned
    // resources before finish; discovery that needs a live process belongs earlier.
    const term = try child.finish();
    if (!term.success()) return error.CommandFailed;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, init.gpa, .limited(1024));
    defer init.gpa.free(bytes);
    if (!std.mem.eql(u8, bytes, "backend-style lifecycle\n")) return error.MissingLog;
}
