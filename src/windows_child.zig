//! Windows ownership for file-backed commands. Assignment to a kill-on-close
//! Job Object happens while the leader is suspended, before it can spawn.
//! Interactive pipes and POSIX signal delivery are deliberately unsupported.
const std = @import("std");
const T = @import("types.zig");
const w = std.os.windows;
const Self = @This();
pub const Term = std.process.Child.Term;

io: std.Io,
pid: ?u32 = null,
handle: ?w.HANDLE = null,
thread: ?w.HANDLE = null,
job: ?w.HANDLE = null,
assigned_to_job: bool = false,
group: T.Group,
stdin: ?std.Io.File = null,
stdout: ?std.Io.File = null,
stderr: ?std.Io.File = null,
term: ?Term = null,

const Startup = extern struct { base: w.STARTUPINFOW, attributes: ?*anyopaque = null };
const Info = extern struct { process: w.HANDLE, thread: w.HANDLE, pid: u32, tid: u32 };
const Limits = extern struct {
    process_time: i64 = 0,
    job_time: i64 = 0,
    flags: u32 = 0,
    min_working_set: usize = 0,
    max_working_set: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority: u32 = 0,
    scheduling: u32 = 0,
};
const ExtendedLimits = extern struct {
    basic: Limits = .{},
    io_counters: [6]u64 = @splat(0),
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};
const Accounting = extern struct {
    times: [4]i64,
    page_faults: u32,
    total: u32,
    active: u32,
    terminated: u32,
};
extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn SetInformationJobObject(w.HANDLE, u32, *const anyopaque, u32) callconv(.winapi) i32;
extern "kernel32" fn AssignProcessToJobObject(w.HANDLE, w.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn QueryInformationJobObject(w.HANDLE, u32, *anyopaque, u32, ?*u32) callconv(.winapi) i32;
extern "kernel32" fn TerminateJobObject(w.HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(w.HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn GetExitCodeProcess(w.HANDLE, *u32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn ResumeThread(w.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(w.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
extern "kernel32" fn OpenProcess(u32, i32, u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn IsProcessInJob(w.HANDLE, w.HANDLE, *i32) callconv(.winapi) i32;
extern "kernel32" fn DuplicateHandle(w.HANDLE, w.HANDLE, w.HANDLE, *w.HANDLE, u32, i32, u32) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, u32, u32, *usize) callconv(.winapi) i32;
extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, u32, usize, *anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) i32;
extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW([*:0]const u16, [*:0]u16, ?*anyopaque, ?*anyopaque, i32, u32, ?*const anyopaque, ?[*:0]const u16, *Startup, *Info) callconv(.winapi) i32;

fn fail() anyerror {
    return switch (w.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        .BAD_FORMAT, .INVALID_EXE_SIGNATURE, .EXE_MARKED_INVALID, .BAD_EXE_FORMAT, .EXE_MACHINE_TYPE_MISMATCH => error.InvalidExe,
        .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.OutOfMemory,
        else => error.WindowsProcessFailed,
    };
}

fn valid(bytes: []const u8) !void {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidOptions;
}

/// CRT-compatible quoting, with no shell interpretation or .cmd/.bat fallback.
fn commandLine(a: std.mem.Allocator, args: []const []const u8) ![:0]u16 {
    var line: std.ArrayList(u8) = .empty;
    for (args, 0..) |arg, i| {
        if (i != 0) try line.append(a, ' ');
        try line.append(a, '"');
        var slashes: usize = 0;
        for (arg) |byte| {
            if (byte == '\\') {
                slashes += 1;
                continue;
            }
            try line.appendNTimes(a, '\\', if (byte == '"') slashes * 2 + 1 else slashes);
            slashes = 0;
            try line.append(a, byte);
        }
        try line.appendNTimes(a, '\\', slashes * 2);
        try line.append(a, '"');
    }
    return std.unicode.utf8ToUtf16LeAllocZ(a, line.items);
}

fn executable(a: std.mem.Allocator, io: std.Io, options: T.SpawnOptions, cwd: []const u8, inherited: std.process.Environ) ![]const u8 {
    const name = options.argv[0];
    const with_extension = if (std.fs.path.extension(name).len == 0) try std.fmt.allocPrint(a, "{s}.exe", .{name}) else name;
    if (!std.ascii.endsWithIgnoreCase(with_extension, ".exe")) return error.InvalidExe;
    if (!options.search_path or std.mem.indexOfAny(u8, name, "/\\:") != null) {
        const path = if (std.fs.path.isAbsolute(with_extension)) with_extension else try std.fs.path.join(a, &.{ cwd, with_extension });
        return std.Io.Dir.cwd().realPathFileAlloc(io, path, a);
    }
    const parent_path = inherited.getAlloc(a, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => "",
        else => return err,
    };
    const path = if (options.search_path_environment == .child and options.environ_map != null)
        options.environ_map.?.get("PATH") orelse ""
    else
        parent_path;
    var parts = std.mem.splitScalar(u8, path, ';');
    while (parts.next()) |part| {
        if (part.len == 0 and options.search_path_environment == .parent) continue;
        const directory = std.mem.trim(u8, part, "\"");
        const base = if (std.fs.path.isAbsolute(directory)) directory else try std.fs.path.join(a, &.{ cwd, directory });
        const candidate = try std.fs.path.join(a, &.{ base, with_extension });
        const file = std.Io.Dir.cwd().openFile(io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        file.close(io);
        return std.Io.Dir.cwd().realPathFileAlloc(io, candidate, a);
    }
    return error.FileNotFound;
}

pub fn spawn(a: std.mem.Allocator, io: std.Io, options: T.SpawnOptions) !Self {
    return spawnUntil(a, io, options, T.deadline(io, options.launch_timeout_ms));
}

pub fn spawnUntil(a: std.mem.Allocator, io: std.Io, options: T.SpawnOptions, end: std.Io.Timestamp) !Self {
    if (options.launch_timeout_ms == 0 or options.argv.len == 0 or options.argv[0].len == 0) return error.InvalidOptions;
    if (std.mem.indexOfScalar(u8, options.argv[0], '"') != null) return error.InvalidOptions;
    for (options.argv) |arg| try valid(arg);
    if (options.stdin == .pipe or options.stdout == .pipe or options.stderr == .pipe) return error.UnsupportedStream;
    if (options.environ_map) |env| for (env.keys(), env.values()) |key, value| {
        try valid(key);
        try valid(value);
        if (key.len == 0 or std.mem.indexOfScalar(u8, key, '=') != null) return error.InvalidOptions;
    };
    var probe: std.Io.Threaded = undefined;
    if (io.vtable.processSpawn != probe.io().vtable.processSpawn) return error.UnsupportedIo;
    try T.check(io, options.cancellation);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(io.userdata.?));
    const inherited = threaded.environ.process_environ;
    const cwd = switch (options.cwd) {
        .inherit => try std.process.currentPathAlloc(io, scratch),
        .path => |path| blk: {
            try valid(path);
            if (path.len == 0) return error.InvalidOptions;
            var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
            defer dir.close(io);
            break :blk try dir.realPathFileAlloc(io, ".", scratch);
        },
        .dir => |dir| try dir.realPathFileAlloc(io, ".", scratch),
    };
    const app = try std.unicode.utf8ToUtf16LeAllocZ(scratch, try executable(scratch, io, options, cwd, inherited));
    const cwd_w = try std.unicode.utf8ToUtf16LeAllocZ(scratch, cwd);
    const line = try commandLine(scratch, options.argv);
    const environment = if (options.environ_map) |env| try env.createWindowsBlock(scratch, .{}) else try inherited.createWindowsBlock(scratch, .{});
    var handles: [3]w.HANDLE = undefined;
    var count: usize = 0;
    defer for (handles[0..count]) |handle| {
        _ = CloseHandle(handle);
    };
    var streams: [3]?w.HANDLE = @splat(null);
    const inherited_streams = .{ w.peb().ProcessParameters.hStdInput, w.peb().ProcessParameters.hStdOutput, w.peb().ProcessParameters.hStdError };
    inline for (.{ options.stdin, options.stdout, options.stderr }, 0..) |stream, i| {
        const source: ?w.HANDLE = switch (stream) {
            .file => |file| file.handle,
            .inherit => inherited_streams[i],
            .ignore => blk: {
                const handle = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), if (i == 0) 0x80000000 else 0x40000000, 3, null, 3, 0, null);
                if (handle == w.INVALID_HANDLE_VALUE) return fail();
                break :blk handle;
            },
            .pipe => unreachable,
        };
        defer if (stream == .ignore) {
            _ = CloseHandle(source.?);
        };
        if (source) |handle| {
            if (handle != w.INVALID_HANDLE_VALUE) {
                if (DuplicateHandle(GetCurrentProcess(), handle, GetCurrentProcess(), &handles[count], 0, 1, 2) == 0) return fail();
                streams[i] = handles[count];
                count += 1;
            }
        }
    }
    var startup: Startup = .{ .base = std.mem.zeroes(w.STARTUPINFOW) };
    startup.base.cb = @sizeOf(Startup);
    startup.base.dwFlags = w.STARTF_USESTDHANDLES;
    startup.base.hStdInput = streams[0];
    startup.base.hStdOutput = streams[1];
    startup.base.hStdError = streams[2];
    var attribute_bytes: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attribute_bytes);
    const attributes = try scratch.alloc(usize, (attribute_bytes + @sizeOf(usize) - 1) / @sizeOf(usize));
    if (InitializeProcThreadAttributeList(attributes.ptr, 1, 0, &attribute_bytes) == 0) return fail();
    defer DeleteProcThreadAttributeList(attributes.ptr);
    startup.attributes = attributes.ptr;
    if (count != 0 and UpdateProcThreadAttribute(attributes.ptr, 0, 0x00020002, &handles, count * @sizeOf(w.HANDLE), null, null) == 0) return fail();
    var child: Self = .{ .io = io, .group = options.group };
    errdefer child.deinit();
    if (options.group == .owned) {
        child.job = CreateJobObjectW(null, null) orelse return fail();
        const limits: ExtendedLimits = .{ .basic = .{ .flags = 0x00002000 } }; // KILL_ON_JOB_CLOSE, no breakaway.
        if (SetInformationJobObject(child.job.?, 9, &limits, @sizeOf(ExtendedLimits)) == 0) return fail();
    }
    try T.check(io, options.cancellation);
    if (T.expired(io, end)) return error.Timeout;
    var info: Info = undefined;
    if (CreateProcessW(app.ptr, line.ptr, null, null, @intFromBool(count != 0), 0x00080000 | 0x00000400 | 0x00000004 | 0x08000000, environment.slice.ptr, cwd_w.ptr, &startup, &info) == 0) return fail();
    child.handle = info.process;
    child.thread = info.thread;
    child.pid = info.pid;
    if (child.job) |job| {
        if (AssignProcessToJobObject(job, info.process) == 0) return fail();
        child.assigned_to_job = true;
    }
    try T.check(io, options.cancellation);
    if (T.expired(io, end)) return error.Timeout;
    if (ResumeThread(info.thread) == std.math.maxInt(u32)) return fail();
    return child;
}

pub fn pollHandle(self: *const Self) ?w.HANDLE {
    return self.handle;
}
pub fn poll(self: *Self) !?Term {
    if (self.term) |term| return term;
    const handle = self.handle orelse return error.Closed;
    switch (WaitForSingleObject(handle, 0)) {
        258 => return null,
        0 => {},
        else => return fail(),
    }
    var code: u32 = undefined;
    if (GetExitCodeProcess(handle, &code) == 0) return fail();
    return if (code <= 255) .{ .exited = @intCast(code) } else .{ .unknown = code };
}
pub fn pollFor(self: *Self, ms: u32) !?Term {
    return self.pollUntil(T.deadline(self.io, ms), null);
}
pub fn pollUntil(self: *Self, end: std.Io.Timestamp, token: ?*const T.Cancellation) !?Term {
    while (true) {
        try T.check(self.io, token);
        if (try self.poll()) |term| return term;
        if (T.expired(self.io, end)) return null;
        try self.io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn terminate(self: *Self) !void {
    if (self.assigned_to_job) {
        // TerminateJobObject removes members from accounting before their
        // handles become signaled. Retain and join members before requesting
        // job-wide termination; never treat ActiveProcesses == 0 as a join.
        // Fixed-size batches keep cleanup allocation-free. Re-querying also
        // covers children created while an earlier batch was being stopped.
        const Pids = extern struct { assigned: u32, listed: u32, ids: [64]usize };
        while (true) {
            var pids: Pids = std.mem.zeroes(Pids);
            if (QueryInformationJobObject(self.job.?, 3, &pids, @sizeOf(Pids), null) == 0 and w.GetLastError() != .MORE_DATA) return fail();
            if (pids.listed == 0) break;
            for (pids.ids[0..@min(pids.listed, pids.ids.len)]) |pid| {
                const handle = OpenProcess(0x00100000 | 0x0400 | 1, 0, @intCast(pid)) orelse {
                    if (w.GetLastError() == .INVALID_PARAMETER) continue; // Already gone.
                    return fail();
                };
                defer _ = CloseHandle(handle);
                var member: i32 = 0;
                if (IsProcessInJob(handle, self.job.?, &member) == 0) return fail();
                if (member == 0) continue; // PID was reused; never touch another owner.
                try terminateHandle(handle);
                if (WaitForSingleObject(handle, std.math.maxInt(u32)) != 0) return fail();
            }
        }
        if (TerminateJobObject(self.job.?, 1) == 0) return fail();
        return;
    }
    if (self.handle) |handle| try terminateHandle(handle);
}
fn terminateHandle(handle: w.HANDLE) !void {
    if (WaitForSingleObject(handle, 0) == 258 and TerminateProcess(handle, 1) == 0) {
        const err = fail();
        if (WaitForSingleObject(handle, 0) != 0) return err;
    }
}
fn join(self: *Self) !Term {
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    if (WaitForSingleObject(self.handle.?, std.math.maxInt(u32)) != 0) return fail();
    const term = (try self.poll()).?;
    if (self.job) |job| while (true) {
        var accounting: Accounting = undefined;
        if (QueryInformationJobObject(job, 1, &accounting, @sizeOf(Accounting), null) == 0) return fail();
        if (accounting.active == 0) break;
        try self.io.sleep(.fromMilliseconds(1), .awake);
    };
    self.term = term;
    self.closeHandles();
    return term;
}
fn closeHandles(self: *Self) void {
    if (self.thread) |h| {
        _ = CloseHandle(h);
    }
    if (self.handle) |h| {
        _ = CloseHandle(h);
    }
    if (self.job) |h| {
        _ = CloseHandle(h);
    }
    self.thread = null;
    self.handle = null;
    self.job = null;
    self.assigned_to_job = false;
    self.pid = null;
}
pub fn finish(self: *Self) !Term {
    if (self.term) |term| return term;
    _ = try self.poll() orelse return error.StillRunning;
    try self.terminate();
    return self.join();
}
pub fn wait(self: *Self, ms: u32) !Term {
    return self.waitUntil(T.deadline(self.io, ms), null);
}
pub fn waitUntil(self: *Self, end: std.Io.Timestamp, token: ?*const T.Cancellation) !Term {
    _ = try self.pollUntil(end, token) orelse return error.Timeout;
    return self.finish();
}
/// Windows has no equivalent POSIX TERM grace contract. Stop force-terminates
/// the owned job and joins it; grace_ms is accepted for shared caller code.
pub fn stop(self: *Self, grace_ms: u32) !Term {
    _ = grace_ms;
    if (self.term) |term| return term;
    if (self.handle == null) return error.Closed;
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    try self.terminate();
    return self.join();
}
pub fn closeStdin(_: *Self) void {}
pub fn deinit(self: *Self) void {
    if (self.handle != null) {
        _ = self.stop(0) catch {
            // Job handle closure still force-cleans descendants after an error.
            if (self.job) |job| {
                _ = CloseHandle(job);
                self.job = null;
            }
            _ = TerminateProcess(self.handle.?, 1);
            _ = WaitForSingleObject(self.handle.?, std.math.maxInt(u32));
            self.closeHandles();
            return;
        };
    }
    self.closeHandles();
}
