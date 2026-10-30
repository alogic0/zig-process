const std = @import("std");
const p = @import("process");
const t = std.testing;
const fixture = @import("test_options").fixture;

test "merged binary streams preserve the borrowed file cursor and nonzero exit" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(t.io, "capture", .{});
    defer file.close(t.io);
    try file.writeStreamingAll(t.io, "prefix");
    var child = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, "binary" }, .stdout = .{ .file = file }, .stderr = .{ .file = file } });
    defer child.deinit();
    try t.expectEqual(@as(u8, 7), (try child.wait(10_000)).exited);
    try file.writeStreamingAll(t.io, "suffix");
    const bytes = try tmp.dir.readFileAlloc(t.io, "capture", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("prefixout\x00\xfferr\xfesuffix", bytes);
}

test "deadline and cancellation retain ownership until explicit cleanup" {
    var child = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, "sleep" } });
    defer child.deinit();
    try t.expectError(error.Timeout, child.wait(1));
    var token: p.Cancellation = .{};
    token.request();
    try t.expectError(error.Canceled, child.waitUntil(std.Io.Clock.awake.now(t.io), &token));
    try t.expect(child.pid != null and child.pollHandle() != null);
    try t.expect(try child.poll() == null);
    _ = try child.stop(0);
    try t.expect(child.pid == null and child.pollHandle() == null);
    child.deinit();
}

const w = std.os.windows;
extern "kernel32" fn OpenProcess(u32, i32, u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn GetProcessId(w.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetProcessHandleCount(w.HANDLE, *u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
extern "kernel32" fn CloseHandle(w.HANDLE) callconv(.winapi) i32;

fn descendant(tmp: std.Io.Dir) !w.HANDLE {
    const end = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(10));
    while (std.Io.Clock.awake.now(t.io).nanoseconds < end.nanoseconds) {
        const bytes = tmp.readFileAlloc(t.io, "ready", t.allocator, .limited(50)) catch |err| switch (err) {
            error.FileNotFound => {
                try t.io.sleep(.fromMilliseconds(1), .awake);
                continue;
            },
            else => return err,
        };
        defer t.allocator.free(bytes);
        return OpenProcess(0x00100000, 0, try std.fmt.parseInt(u32, bytes, 10)) orelse error.OpenDescendantFailed;
    }
    return error.DescendantDidNotStart;
}

test "observing leader exit retains descendants until finish joins the owned job" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var child = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, "tree", root, "exit" } });
    defer child.deinit();
    const handle = try descendant(tmp.dir);
    defer _ = CloseHandle(handle);
    try t.expectEqual(@as(u8, 7), (try child.pollFor(10_000)).?.exited);
    try t.expectEqual(@as(u8, 7), (try child.poll()).?.exited);
    try t.expectEqual(@as(u32, 258), WaitForSingleObject(handle, 0));
    try t.expect(child.pid != null);
    try t.expectEqual(@as(u8, 7), (try child.finish()).exited);
    try t.expectEqual(@as(u32, 0), WaitForSingleObject(handle, 0));
    try t.expectEqual(@as(u8, 7), (try child.finish()).exited);
}

test "timeout deinit kills descendants without touching an independent owner" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var unrelated = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, "sleep" } });
    defer unrelated.deinit();
    var child = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, "tree", root, "sleep" } });
    defer child.deinit();
    const handle = try descendant(tmp.dir);
    defer _ = CloseHandle(handle);
    try t.expectError(error.Timeout, child.wait(1));
    child.deinit();
    try t.expectEqual(@as(u32, 0), WaitForSingleObject(handle, 0));
    try t.expect(try unrelated.poll() == null);
}

test "Unicode cwd environment and literal CRT arguments survive without a shell" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "перенос space", .default_dir);
    var dir = try tmp.dir.openDir(t.io, "перенос space", .{});
    defer dir.close(t.io);
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("FIXTURE_VALUE", "игра assets");
    try env.put("PATH", "nonexistent");
    const root = try dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const expected = [_][]const u8{ "", "plain", "игра assets", "a\"b", "a\\\"b", "trailing\\", "$HOME;*.txt" };
    const absolute_fixture = try std.Io.Dir.cwd().realPathFileAlloc(t.io, fixture, t.allocator);
    defer t.allocator.free(absolute_fixture);
    for ([_]std.process.Child.Cwd{ .{ .dir = dir }, .{ .path = root } }) |cwd| {
        const file = try dir.createFile(t.io, "capture", .{});
        defer file.close(t.io);
        var child = try p.Child.spawn(t.allocator, t.io, .{ .argv = &(.{ absolute_fixture, "inspect" } ++ expected), .cwd = cwd, .environ_map = &env, .stdout = .{ .file = file } });
        defer child.deinit();
        try t.expect((try child.wait(10_000)).success());
        const bytes = try dir.readFileAlloc(t.io, "capture", t.allocator, .limited(4096));
        defer t.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, bytes, .{});
        defer parsed.deinit();
        const value = parsed.value.object;
        try t.expectEqualStrings(root, value.get("cwd").?.string);
        try t.expectEqualStrings("игра assets", value.get("value").?.string);
        try t.expectEqualStrings("nonexistent", value.get("path").?.string);
        for (expected, value.get("args").?.array.items) |want, got| try t.expectEqualStrings(want, got.string);
    }
}

test "failed launches unsupported pipes and canceled launch release all handles" {
    // Warm the backend before measuring handles owned by these operations.
    var warm = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, "binary" } });
    _ = try warm.wait(10_000);
    warm.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "invalid.exe", .data = "not executable" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "invalid.exe", t.allocator);
    defer t.allocator.free(path);
    var before: u32 = 0;
    try t.expect(GetProcessHandleCount(GetCurrentProcess(), &before) != 0);
    for (0..10) |_| {
        try t.expectError(error.FileNotFound, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{"Z:\\missing-process-928381.exe"} }));
        try t.expectError(error.InvalidExe, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{path} }));
        try t.expectError(error.UnsupportedStream, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{fixture}, .stdout = .pipe }));
        var token: p.Cancellation = .{};
        token.request();
        try t.expectError(error.Canceled, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{fixture}, .cancellation = &token }));
    }
    var after: u32 = 0;
    try t.expect(GetProcessHandleCount(GetCurrentProcess(), &after) != 0);
    try t.expectEqual(before, after);
}

test "PATH lookup is explicit and selects the requested environment" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try std.Io.Dir.cwd().copyFile(fixture, tmp.dir, "search-fixture.exe", t.io, .{});
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("PATH", root);
    var found = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ "search-fixture", "binary" }, .environ_map = &env, .search_path = true });
    defer found.deinit();
    try t.expectEqual(@as(u8, 7), (try found.wait(10_000)).exited);
    try t.expectError(error.FileNotFound, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{"search-fixture"}, .environ_map = &env }));
    try t.expectError(error.FileNotFound, p.Child.spawn(t.allocator, t.io, .{ .argv = &.{"cmd.exe"}, .environ_map = &env, .search_path = true }));
    var parent = try p.Child.spawn(t.allocator, t.io, .{ .argv = &.{ fixture, "parent-search" }, .environ_map = &env });
    defer parent.deinit();
    try t.expectEqual(@as(u8, 7), (try parent.wait(10_000)).exited);
}
