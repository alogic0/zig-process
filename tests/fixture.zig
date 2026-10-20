const std = @import("std");
const linux = std.os.linux;
const process = @import("process");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const io = init.io;
    const mode = args[1];
    if (std.mem.eql(u8, mode, "pipe-echo")) {
        if (args.len > 2) {
            while (true) {
                std.Io.Dir.cwd().access(io, args[2], .{}) catch |err| switch (err) {
                    error.FileNotFound => {
                        try io.sleep(.fromMilliseconds(1), .awake);
                        continue;
                    },
                    else => return err,
                };
                break;
            }
        }
        var buffer: [1021]u8 = undefined;
        while (true) {
            const n = std.Io.File.stdin().readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            try std.Io.File.stdout().writeStreamingAll(io, buffer[0..n]);
        }
    } else if (std.mem.eql(u8, mode, "echo")) {
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
    } else if (std.mem.eql(u8, mode, "report")) {
        try std.Io.File.stdout().writeStreamingAll(io, "out\x00\xff");
        try std.Io.File.stderr().writeStreamingAll(io, "err\xfe");
        if (std.mem.eql(u8, args[2], "exit")) std.process.exit(7);
        try io.sleep(.fromSeconds(30), .awake);
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
        if (args.len > 2 and std.mem.eql(u8, args[2], "timed")) {
            const term = try child.pollUntil(end, null) orelse return error.LeaderDidNotExit;
            if (term.exited != 7) return error.WrongObservedStatus;
            if ((try child.pollFor(0)).?.exited != 7) return error.UnstableObservation;
        } else {
            while (try child.poll() == null) {
                if (std.Io.Clock.awake.now(io).nanoseconds >= end.nanoseconds) return error.LeaderDidNotExit;
                try io.sleep(.fromMilliseconds(1), .awake);
            }
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
        var descendant_info = std.mem.zeroes(linux.siginfo_t);
        while (true) switch (linux.errno(linux.waitid(.PID, descendant, &descendant_info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.DescendantObservationFailed,
        };
        if (descendant_info.fields.common.first.piduid.pid != 0) return error.PollKilledDescendant;
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
    } else if (std.mem.eql(u8, mode, "capture-exit-test")) {
        // Only this isolated fixture adopts the pipe-owning descendant.
        if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0)) != .SUCCESS) return error.SubreaperFailed;
        var random: [12]u8 = undefined;
        io.random(&random);
        const root = try a.print("/tmp/process-capture-{s}", .{std.fmt.bytesToHex(random, .lower)});
        try std.Io.Dir.cwd().createDir(io, root, .fromMode(0o700));
        defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
        const hold = std.mem.eql(u8, args[2], "hold");
        // The writer waits for the leader's zombie state, not a scheduling delay.
        const script = try a.print(
            "leader=$$; (while IFS= read -r state < /proc/$leader/stat; do case \"$state\" in *\") Z \"*) break;; esac; done; printf late; printf error >&2; {s}) & echo $! > descendant; exit 7",
            .{if (hold) "exec /bin/sleep 30" else "exit 0"},
        );
        const result = try process.run(init.gpa, io, .{
            .spawn = .{ .argv = &.{ "/bin/sh", "-c", script }, .cwd = .{ .path = root } },
            .timeout_ms = if (hold) 500 else 3000,
            .stdout_limit = 4,
            .stderr_limit = 5,
            .exit_policy = .drain_output,
        });
        defer result.deinit(init.gpa);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try a.print("{s}/descendant", .{root}), a, .limited(64));
        const descendant = try std.fmt.parseInt(i32, std.mem.trim(u8, bytes, "\n"), 10);
        var joined = false;
        defer if (!joined) {
            _ = linux.kill(descendant, .KILL);
            var status: i32 = 0;
            while (linux.errno(linux.wait4(descendant, &status, 0, null)) == .INTR) {}
        };
        if (result.outcome != (if (hold) process.Outcome.timed_out else .completed) or result.term != .exited or result.term.exited != 7) return error.WrongCaptureOutcome;
        if (!std.mem.eql(u8, result.stdout, "late") or !std.mem.eql(u8, result.stderr, "error")) return error.MissingLateOutput;
        var status: i32 = 0;
        while (true) {
            const rc = linux.wait4(descendant, &status, 0, null);
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS or rc != descendant) return error.DescendantWaitFailed;
            joined = true;
            break;
        }
        if (hold and (!linux.W.IFSIGNALED(@bitCast(status)) or linux.W.TERMSIG(@bitCast(status)) != .KILL)) return error.DescendantNotKilled;
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
