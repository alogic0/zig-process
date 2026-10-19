const std = @import("std");
const p = @import("process");
const config = @import("test_options");
const fixture = if (std.fs.path.isAbsolute(config.fixture)) config.fixture else config.workspace_root ++ "/" ++ config.fixture;
const t = std.testing;
const linux = std.os.linux;
test "capture direct arguments binary bytes and nonzero exit" {
    const result = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ fixture, "echo", "hi \xff" } } });
    defer result.deinit(t.allocator);
    try t.expectEqual(p.Outcome.completed, result.outcome);
    try t.expectEqual(@as(u8, 7), result.term.exited);
    try t.expectEqualStrings("hi \xff", result.stdout);
    try t.expectEqualStrings("err", result.stderr);
    try t.expect(!result.success());
}

test "cwd handles paths and child environment PATH lookup" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(directory);
    try tmp.dir.symLink(t.io, fixture, "fixture", .{});
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("PATH", ":/does-not-exist");
    try env.put("FIXTURE_VALUE", "explicit environment");
    for ([_]std.process.Child.Cwd{ .{ .dir = tmp.dir }, .{ .path = directory } }) |cwd| {
        const result = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ "fixture", "inspect" }, .cwd = cwd, .environ_map = &env, .search_path = true } });
        defer result.deinit(t.allocator);
        try t.expect(result.success());
        const value = try std.json.parseFromSlice(std.json.Value, t.allocator, result.stdout, .{});
        defer value.deinit();
        try t.expectEqualStrings(directory, value.value.object.get("cwd").?.string);
        try t.expectEqualStrings("explicit environment", value.value.object.get("value").?.string);
    }
    // A slash bypasses PATH, including relative interpreter scripts.
    const script = try tmp.dir.createFile(t.io, "script", .{ .permissions = .fromMode(0o700) });
    try script.writeStreamingAll(t.io, "#!/bin/sh\nprintf relative-script");
    script.close(t.io);
    const relative = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{"./script"}, .cwd = .{ .dir = tmp.dir } } });
    defer relative.deinit(t.allocator);
    try t.expectEqualStrings("relative-script", relative.stdout);
    try t.expect(relative.success());
}

test "independent stdout stderr limits exact zero and simultaneous large output" {
    for ([_]usize{ 0, 1, 4096, 200_000 }) |size| {
        const count = try std.fmt.allocPrint(t.allocator, "{d}", .{size});
        defer t.allocator.free(count);
        const result = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ fixture, "exact", count } }, .stdout_limit = size, .stderr_limit = size });
        defer result.deinit(t.allocator);
        try t.expect(result.success());
        try t.expectEqual(size, result.stdout.len);
        try t.expectEqual(size, result.stderr.len);
    }
    for ([_][2]usize{ .{ 0, 100 }, .{ 100, 0 }, .{ 4096, 5000 }, .{ 5000, 4096 } }) |limits| {
        const result = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ fixture, "exact", "5000" } }, .stdout_limit = limits[0], .stderr_limit = limits[1] });
        defer result.deinit(t.allocator);
        try t.expectEqual(p.Outcome.output_limit, result.outcome);
        try t.expect(result.stdout.len <= limits[0] and result.stderr.len <= limits[1]);
        try t.expect(!result.success());
    }
    const binary = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ "/bin/sh", "-c", "printf '\\000\\377'" } }, .stdout_limit = 2 });
    defer binary.deinit(t.allocator);
    try t.expectEqualStrings("\x00\xff", binary.stdout);
}

test "failed launches and invalid options are errors with exact child ownership" {
    try t.expectError(error.FileNotFound, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{"/this-executable-does-not-exist"} }));
    try t.expectError(error.InvalidOptions, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{} }));
    try t.expectError(error.InvalidOptions, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{"bad\x00suffix"} }));
    try t.expectError(error.InvalidOptions, p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{fixture}, .stdin = .pipe } }));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const plain = try tmp.dir.createFile(t.io, "plain", .{ .permissions = .fromMode(0o700) });
    try plain.writeStreamingAll(t.io, "not an executable format\n");
    plain.close(t.io);
    try t.expectError(error.InvalidExe, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{"./plain"}, .cwd = .{ .dir = tmp.dir } }));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "denied", .data = "no permission" });
    try t.expectError(error.AccessDenied, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{"./denied"}, .cwd = .{ .dir = tmp.dir } }));
    const signaled = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ fixture, "signal" } } });
    defer signaled.deinit(t.allocator);
    try t.expectEqual(p.Outcome.completed, signaled.outcome);
    try t.expectEqual(linux.SIG.TERM, signaled.term.signal);
}

fn ready(child: *p.Child) !void {
    const end = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(3));
    var bytes: [32]u8 = undefined;
    while (std.Io.Clock.awake.now(t.io).nanoseconds < end.nanoseconds) {
        const n = linux.read(child.stdout.?.handle, &bytes, bytes.len);
        if (linux.errno(n) == .SUCCESS and n > 0) return;
        if (linux.errno(n) != .AGAIN and linux.errno(n) != .INTR) return error.ExpectedReady;
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.FixtureNotReady;
}

test "poll wait timeout graceful forced stop and idempotent cleanup" {
    for ([_][]const u8{ "sleep", "ignore" }) |mode| {
        var child = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, mode }, .stdout = .pipe });
        defer child.deinit();
        const pid = child.pid.?;
        try ready(&child);
        try t.expect(child.pollHandle() != null);
        try t.expectEqual(@as(?p.Child.Term, null), try child.poll());
        try t.expectError(error.StillRunning, child.finish());
        try t.expectError(error.Timeout, child.wait(5));
        try t.expectEqual(pid, child.pid.?);
        const term = try child.stop(10);
        try t.expectEqual(if (std.mem.eql(u8, mode, "ignore")) linux.SIG.KILL else linux.SIG.TERM, term.signal);
        try t.expectEqualDeep(term, try child.wait(0));
        try t.expect(child.pid == null and child.pidfd == null);
        try t.expectEqual(linux.E.SRCH, linux.errno(linux.kill(pid, @fromBackingInt(0))));
        child.deinit();
        child.deinit();
    }
}

test "deadline includes waiting after output closes and retains partial bytes" {
    for ([_][]const u8{ "sleep", "closed" }) |mode| {
        const start = std.Io.Clock.awake.now(t.io);
        const result = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ fixture, mode } }, .timeout_ms = 100 });
        defer result.deinit(t.allocator);
        try t.expectEqual(p.Outcome.timed_out, result.outcome);
        try t.expectEqualStrings("ready\n", result.stdout);
        try t.expect(start.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds() < 3000);
    }
}

const Gate = struct {
    dir: std.Io.Dir,
    flag: *p.Cancellation,
    observed: bool = false,
    pid: i32 = 0,
    fn cancel(self: *Gate) void {
        self.watch() catch {};
        self.flag.request();
    }
    fn watch(self: *Gate) !void {
        for (0..3000) |_| {
            const bytes = self.dir.readFileAlloc(t.io, "ready", std.heap.page_allocator, .limited(100)) catch {
                try t.io.sleep(.fromMilliseconds(1), .awake);
                continue;
            };
            defer std.heap.page_allocator.free(bytes);
            self.pid = std.fmt.parseInt(i32, bytes, 10) catch continue;
            self.observed = true;
            return;
        }
    }
};
test "atomic cancellation before and during execution joins before return" {
    var flag: p.Cancellation = .{};
    flag.request();
    try t.expectError(error.Canceled, p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{fixture}, .cancellation = &flag } }));
    flag = .{};
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var gate: Gate = .{ .dir = tmp.dir, .flag = &flag };
    const thread = try std.Thread.spawn(.{}, Gate.cancel, .{&gate});
    const pending = p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ fixture, "sleep", "ready" }, .cwd = .{ .dir = tmp.dir }, .cancellation = &flag } });
    thread.join();
    // The fixture can run before the parent consumes its exec acknowledgement.
    // Both documented cancellation outcomes must join before returning.
    if (pending) |result| {
        defer result.deinit(t.allocator);
        try t.expectEqual(p.Outcome.canceled, result.outcome);
    } else |err| try t.expectEqual(error.Canceled, err);
    try t.expect(gate.observed);
    try t.expectEqual(linux.E.SRCH, linux.errno(linux.kill(gate.pid, @fromBackingInt(0))));
}

test "unrelated child remains independently observable and waitable" {
    var other = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ "/bin/sh", "-c", "exit 23" }, .group = .child_only });
    defer other.deinit();
    for (0..8) |_| {
        try t.expectError(error.FileNotFound, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{"/nonexistent/owned-child"} }));
    }
    try t.expectEqual(@as(u8, 23), (try other.wait(2000)).exited);
}

test "borrowed file redirection stdin pipe and descriptor isolation" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(t.io, "capture", .{});
    defer file.close(t.io);
    var child = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, "stdin" }, .stdin = .pipe, .stdout = .{ .file = file }, .stderr = .inherit });
    defer child.deinit();
    try child.stdin.?.writeStreamingAll(t.io, "input");
    child.closeStdin();
    try t.expect((try child.wait(2000)).success());
    // Borrowed output remains usable after child cleanup.
    child.deinit();
    try file.writeStreamingAll(t.io, "-parent");
    const bytes = try tmp.dir.readFileAlloc(t.io, "capture", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("input-parent", bytes);
    // Deliberately create a non-CLOEXEC descriptor well above ordinary startup FDs.
    const raw = linux.fcntl(file.handle, linux.F.DUPFD, 200);
    try t.expectEqual(linux.E.SUCCESS, linux.errno(raw));
    defer _ = linux.close(@intCast(raw));
    const number = try std.fmt.allocPrint(t.allocator, "{d}", .{raw});
    defer t.allocator.free(number);
    const checked = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ fixture, "fds", number } } });
    defer checked.deinit(t.allocator);
    try t.expect(checked.success());
}

fn fdCount() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(t.io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(t.io) != null) count += 1;
    return count;
}
fn children() ![]u8 {
    var path: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&path, "/proc/self/task/{d}/children", .{linux.gettid()});
    const file = try std.Io.Dir.cwd().openFile(t.io, name, .{});
    defer file.close(t.io);
    var buffer: [256]u8 = undefined;
    var reader = file.readerStreaming(t.io, &buffer);
    return reader.interface.allocRemaining(t.allocator, .limited(65536));
}
fn allocationCase(a: std.mem.Allocator) !void {
    // Force arena growth to allocate instead of relying on heap-layout-dependent
    // in-place resize success, so every failure index is reproducible.
    var fixed: NonResizing = .{ .parent = a };
    const allocator = fixed.allocator();
    const result = try p.run(allocator, t.io, .{ .spawn = .{ .argv = &.{ fixture, "echo", "allocation" } }, .stdout_limit = 20, .stderr_limit = 20 });
    defer result.deinit(allocator);
}
const NonResizing = struct {
    parent: std.mem.Allocator,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.parent.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.parent.rawFree(memory, alignment, ra);
    }
};
test "allocation failures and repeated failed exec leave descriptors stable" {
    try allocationCase(t.allocator);
    const before = try fdCount();
    const before_children = try children();
    defer t.allocator.free(before_children);
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
    for (0..24) |_| {
        try t.expectError(error.FileNotFound, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{"/nonexistent/owned-child"}, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe }));
    }
    try t.expectEqual(before, try fdCount());
    const after_children = try children();
    defer t.allocator.free(after_children);
    try t.expectEqualStrings(before_children, after_children);
}

test "group cleanup and closed standard descriptors in isolated helpers" {
    for ([_][]const u8{ "group-test", "closed-stdio-test" }) |mode| {
        const result = try p.run(t.allocator, t.io, .{ .spawn = .{ .argv = &.{ fixture, mode } }, .timeout_ms = 5000 });
        defer result.deinit(t.allocator);
        if (!result.success()) std.debug.print("helper {s}: {s}\n", .{ mode, result.stderr });
        try t.expect(result.success());
    }
}

test "std Io cancellation joins command and preserves low-level wait ownership" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var future = try t.io.concurrent(p.run, .{ t.allocator, t.io, p.RunOptions{ .spawn = .{ .argv = &.{ fixture, "sleep", "ready" }, .cwd = .{ .dir = tmp.dir } } } });
    var consumed = false;
    defer if (!consumed) {
        const value = future.cancel(t.io) catch null;
        if (value) |r| r.deinit(t.allocator);
    };
    var flag: p.Cancellation = .{};
    var gate: Gate = .{ .dir = tmp.dir, .flag = &flag };
    try gate.watch();
    try t.expect(gate.observed);
    const pending = future.cancel(t.io);
    consumed = true;
    if (pending) |result| {
        defer result.deinit(t.allocator);
        try t.expectEqual(p.Outcome.canceled, result.outcome);
        try t.expect(std.mem.startsWith(u8, "ready\n", result.stdout));
    } else |err| try t.expectEqual(error.Canceled, err);
    try t.expectEqual(linux.E.SRCH, linux.errno(linux.kill(gate.pid, @fromBackingInt(0))));
    var child = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, "sleep" }, .stdout = .pipe });
    defer child.deinit();
    try ready(&child);
    const pid = child.pid.?;
    var waiter = try t.io.concurrent(p.Child.wait, .{ &child, @as(u32, 5000) });
    try t.expectError(error.Canceled, waiter.cancel(t.io));
    try t.expectEqual(pid, child.pid.?);
    try t.expect(child.pidfd != null and try child.poll() == null);
    _ = try child.stop(0);
}

test "concurrent independent command owners preserve separate results" {
    var first = try t.io.concurrent(p.run, .{ t.allocator, t.io, p.RunOptions{ .spawn = .{ .argv = &.{ fixture, "exact", "70000" } } } });
    defer {
        const r = first.cancel(t.io) catch null;
        if (r) |result| result.deinit(t.allocator);
    }
    var second = try t.io.concurrent(p.run, .{ t.allocator, t.io, p.RunOptions{ .spawn = .{ .argv = &.{ fixture, "echo", "second" } } } });
    defer {
        const r = second.cancel(t.io) catch null;
        if (r) |result| result.deinit(t.allocator);
    }
    const a = try first.await(t.io);
    const b = try second.await(t.io);
    try t.expect(a.success());
    try t.expectEqual(@as(usize, 70000), a.stdout.len);
    try t.expectEqual(@as(u8, 7), b.term.exited);
    try t.expectEqualStrings("second", b.stdout);
}
