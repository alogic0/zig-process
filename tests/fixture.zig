const std = @import("std");
const linux = std.os.linux;
const process = @import("process");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const io = init.io;
    const mode = args[1];
    if (std.mem.eql(u8, mode, "echo")) {
        try std.Io.File.stdout().writeStreamingAll(io, args[2]);
        try std.Io.File.stderr().writeStreamingAll(io, "err");
        std.process.exit(7);
    } else if (std.mem.eql(u8, mode, "exact")) {
        var left = try std.fmt.parseInt(usize, args[2], 10);
        while (left > 0) {
            const n = @min(left, 4096);
            try std.Io.File.stdout().writeStreamingAll(io, @as([4096]u8, @splat('x'))[0..n]);
            try std.Io.File.stderr().writeStreamingAll(io, @as([4096]u8, @splat('y'))[0..n]);
            left -= n;
        }
    } else if (std.mem.eql(u8, mode, "inspect")) {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
        try std.Io.File.stdout().writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, .{ .cwd = cwd, .value = init.environ_map.get("FIXTURE_VALUE"), .path = init.environ_map.get("PATH") }, .{}));
    } else if (std.mem.eql(u8, mode, "fds")) {
        const forbidden = try std.fmt.parseInt(i32, args[2], 10);
        if (linux.errno(linux.fcntl(forbidden, linux.F.GETFD, 0)) != .BADF) return error.LeakedDescriptor;
    } else if (std.mem.eql(u8, mode, "stdin")) {
        var buffer: [100]u8 = undefined;
        const n = try std.Io.File.stdin().readStreaming(io, &.{&buffer});
        try std.Io.File.stdout().writeStreamingAll(io, buffer[0..n]);
    } else if (std.mem.eql(u8, mode, "signal")) {
        _ = linux.kill(linux.getpid(), .TERM);
    } else if (std.mem.eql(u8, mode, "sleep") or std.mem.eql(u8, mode, "closed") or std.mem.eql(u8, mode, "ignore")) {
        if (std.mem.eql(u8, mode, "ignore")) {
            const action: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
            _ = linux.sigaction(.TERM, &action, null);
        }
        try std.Io.File.stdout().writeStreamingAll(io, "ready\n");
        if (args.len > 2) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = try a.print("{d}", .{linux.getpid()}) });
        if (std.mem.eql(u8, mode, "closed")) {
            std.Io.File.stdout().close(io);
            std.Io.File.stderr().close(io);
        }
        try io.sleep(.fromSeconds(30), .awake);
    } else if (std.mem.eql(u8, mode, "group-test")) {
        // Process-wide policy is confined to this fixture executable. Adopt the
        // one grandchild so the test itself never leaves an orphan zombie.
        if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0)) != .SUCCESS) return error.SubreaperFailed;
        var child = try process.Child.spawn(init.gpa, io, .{ .argv = &.{ "/bin/sh", "-c", "/bin/sleep 30 & echo $!; exit 7" }, .stdout = .pipe });
        defer child.deinit();
        const end = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
        while (try child.poll() == null) {
            if (std.Io.Clock.awake.now(io).nanoseconds >= end.nanoseconds) return error.LeaderDidNotExit;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        var buffer: [64]u8 = undefined;
        const n = linux.read(child.stdout.?.handle, &buffer, buffer.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return error.MissingDescendant;
        const descendant = try std.fmt.parseInt(i32, std.mem.trim(u8, buffer[0..n], "\n"), 10);
        var descendant_owned = true;
        defer if (descendant_owned) {
            _ = linux.kill(descendant, .KILL);
            var status: i32 = 0;
            _ = linux.wait4(descendant, &status, 0, null);
        };
        if (child.pid == null or child.pollHandle() == null) return error.PollConsumedOwnership;
        if ((try child.finish()).exited != 7) return error.WrongLeaderStatus;
        var status: i32 = 0;
        while (true) {
            const rc = linux.wait4(descendant, &status, linux.W.NOHANG, null);
            if (linux.errno(rc) != .SUCCESS and linux.errno(rc) != .INTR) return error.DescendantWaitFailed;
            if (rc == descendant) {
                descendant_owned = false;
                break;
            }
            if (std.Io.Clock.awake.now(io).nanoseconds >= end.nanoseconds) return error.DescendantStillRunning;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        if (!linux.W.IFSIGNALED(@bitCast(status)) or linux.W.TERMSIG(@bitCast(status)) != .KILL) return error.DescendantNotKilled;
    } else if (std.mem.eql(u8, mode, "closed-stdio-test")) {
        const exe = try std.process.executablePathAlloc(io, a);
        _ = linux.close(0);
        _ = linux.close(1);
        var child = try process.Child.spawn(init.gpa, io, .{ .argv = &.{ exe, "echo", "closed-stdio" } });
        defer child.deinit();
        if ((try child.wait(2000)).exited != 7) return error.ClosedStdioFailed;
        if (linux.errno(linux.fcntl(0, linux.F.GETFD, 0)) != .BADF or linux.errno(linux.fcntl(1, linux.F.GETFD, 0)) != .BADF) return error.ParentStdioChanged;
        if (process.Child.spawn(init.gpa, io, .{ .argv = &.{exe}, .stdin = .inherit })) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.InheritedClosedDescriptor;
        } else |err| if (err != error.InvalidHandle) return err;
    } else return error.UnknownFixtureMode;
}
