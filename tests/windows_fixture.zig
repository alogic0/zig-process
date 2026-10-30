const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const io = init.io;
    if (std.mem.eql(u8, args[1], "binary")) {
        try std.Io.File.stdout().writeStreamingAll(io, "out\x00\xff");
        try std.Io.File.stderr().writeStreamingAll(io, "err\xfe");
        std.process.exit(7);
    } else if (std.mem.eql(u8, args[1], "inspect")) {
        try std.Io.File.stdout().writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, .{
            .args = args[2..],
            .cwd = try std.process.currentPathAlloc(io, a),
            .value = init.environ_map.get("FIXTURE_VALUE"),
            .path = init.environ_map.get("PATH"),
        }, .{}));
    } else if (std.mem.eql(u8, args[1], "parent-search")) {
        var env: std.process.Environ.Map = .init(a);
        defer env.deinit();
        try env.put("PATH", "nonexistent");
        var child = try @import("process").Child.spawn(a, io, .{ .argv = &.{ "search-fixture", "binary" }, .environ_map = &env, .search_path = true, .search_path_environment = .parent });
        defer child.deinit();
        std.process.exit((try child.wait(10_000)).exited);
    } else if (std.mem.eql(u8, args[1], "sleep")) {
        try io.sleep(.fromSeconds(60), .awake);
    } else if (std.mem.eql(u8, args[1], "tree")) {
        const exe = try std.process.executablePathAlloc(io, a);
        const child = try std.process.spawn(io, .{ .argv = &.{ exe, "sleep" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        const w = std.os.windows;
        const Win = struct {
            extern "kernel32" fn GetProcessId(w.HANDLE) callconv(.winapi) u32;
            extern "kernel32" fn CloseHandle(w.HANDLE) callconv(.winapi) i32;
        };
        defer _ = Win.CloseHandle(child.id.?);
        defer _ = Win.CloseHandle(child.thread_handle);
        var dir = try std.Io.Dir.cwd().openDir(io, args[2], .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "ready.tmp", .data = try a.print("{d}", .{Win.GetProcessId(child.id.?)}) });
        try dir.rename("ready.tmp", dir, "ready", io);
        if (std.mem.eql(u8, args[3], "exit")) std.process.exit(7);
        try io.sleep(.fromSeconds(60), .awake);
    } else return error.UnknownFixture;
}
