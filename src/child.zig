//! Linux/Threaded launch and exact-child ownership. See DESIGN.md for lifecycle.
const std = @import("std");
const linux = std.os.linux;
const T = @import("types.zig");
const File = std.Io.File;
const Self = @This();
pub const Term = std.process.Child.Term;

io: std.Io,
pid: ?linux.pid_t = null,
pidfd: ?linux.fd_t = null,
group: T.Group,
stdin: ?File = null,
stdout: ?File = null,
stderr: ?File = null,
term: ?Term = null,

pub fn spawn(a: std.mem.Allocator, io: std.Io, options: T.SpawnOptions) !Self {
    if (options.launch_timeout_ms == 0) return error.InvalidOptions;
    return spawnUntil(a, io, options, T.deadline(io, options.launch_timeout_ms));
}

/// For composed operations whose deadline starts before allocations/launch.
pub fn spawnUntil(a: std.mem.Allocator, io: std.Io, options: T.SpawnOptions, end: std.Io.Timestamp) !Self {
    var probe: std.Io.Threaded = undefined;
    if (io.vtable.processSpawn != probe.io().vtable.processSpawn) return error.UnsupportedIo;
    try T.check(io, options.cancellation);
    if (options.argv.len == 0 or options.argv[0].len == 0) return error.InvalidOptions;
    for (options.argv) |arg| if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidOptions;
    if (options.cwd == .path and (options.cwd.path.len == 0 or std.mem.indexOfScalar(u8, options.cwd.path, 0) != null)) return error.InvalidOptions;
    if (options.environ_map) |env| {
        for (env.keys(), env.values()) |key, value| {
            if (key.len == 0 or std.mem.indexOfAny(u8, key, "=\x00") != null or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidOptions;
        }
    }
    var disposition: linux.Sigaction = undefined;
    try checked(linux.sigaction(.CHLD, null, &disposition));
    if (disposition.handler.handler == linux.SIG.IGN or disposition.flags & linux.SA.NOCLDWAIT != 0) return error.IncompatibleChildReaping;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(io.userdata.?));
    const inherited = threaded.environ.process_environ;
    const environment = if (options.environ_map) |env| try env.createPosixBlock(scratch, .{ .zig_progress_fd = -1 }) else try inherited.createPosixBlock(scratch, .{ .zig_progress_fd = -1 });
    const args = try scratch.allocSentinel(?[*:0]const u8, options.argv.len, null);
    for (args, options.argv) |*dest, arg| dest.* = (try scratch.dupeSentinel(u8, arg, 0)).ptr;
    var paths: std.ArrayList([:0]const u8) = .empty;
    if (options.search_path and std.mem.indexOfScalar(u8, options.argv[0], '/') == null) {
        const path = (if (options.environ_map) |env| env.get("PATH") else inherited.getPosix("PATH")) orelse "/usr/bin:/bin";
        var parts = std.mem.splitScalar(u8, path, ':');
        while (parts.next()) |part| {
            const candidate = if (part.len == 0) options.argv[0] else try std.fs.path.join(scratch, &.{ part, options.argv[0] });
            try paths.append(scratch, try scratch.dupeSentinel(u8, candidate, 0));
        }
    } else try paths.append(scratch, try scratch.dupeSentinel(u8, options.argv[0], 0));

    // Snapshot supplied/inherited stdio before opening anything which could
    // occupy a currently closed standard descriptor.
    var streams: [3]Prepared = @splat(.{});
    defer for (&streams) |*stream| stream.deinit();
    const requested = [_]T.Stream{ options.stdin, options.stdout, options.stderr };
    for (requested, 0..) |stream, i| if (stream == .inherit or stream == .file) {
        streams[i] = try Prepared.init(io, stream, @intCast(i));
    };
    // Open before fork; both path and directory cwd work for relative scripts.
    var cwd = switch (options.cwd) {
        .inherit => try std.Io.Dir.cwd().openDir(io, ".", .{}),
        .path => |path| try std.Io.Dir.cwd().openDir(io, path, .{}),
        .dir => |dir| try dir.openDir(io, ".", .{}),
    };
    defer cwd.close(io);
    // Standard descriptors may be closed by the caller. All setup handles must
    // be above 2 before dup3 replaces the child's standard streams.
    const cwd_fd = try duplicate(cwd.handle);
    defer close(cwd_fd);
    for (requested, 0..) |stream, i| if (streams[i].child < 0) {
        streams[i] = try Prepared.init(io, stream, @intCast(i));
    };
    var errors = try makePipe();
    defer for (errors) |fd| if (fd >= 0) close(fd);
    try nonblocking(errors[0]);
    try T.check(io, options.cancellation);
    if (T.expired(io, end)) return error.Timeout;

    // Block inherited handlers until child dispositions have been reset. The
    // parent restores its thread's mask immediately, before any I/O or return.
    const full = linux.sigfillset();
    var old_mask: linux.sigset_t = undefined;
    try checked(linux.sigprocmask(linux.SIG.BLOCK, &full, &old_mask));
    const forked = linux.fork();
    if (linux.errno(forked) == .SUCCESS and forked == 0) {
        childMain(options.group, cwd_fd, streams, errors[1], paths.items, args, environment.slice);
    }
    const restored = linux.sigprocmask(linux.SIG.SETMASK, &old_mask, null);
    if (linux.errno(forked) != .SUCCESS) return errnoError(linux.errno(forked));
    var child: Self = .{ .io = io, .pid = @intCast(forked), .group = options.group };
    errdefer child.deinit();
    try checked(restored);
    const opened = linux.pidfd_open(child.pid.?, 0);
    try checked(opened);
    child.pidfd = @intCast(opened);
    inline for (.{ "stdin", "stdout", "stderr" }, 0..) |name, i| {
        if (streams[i].parent >= 0) {
            @field(child, name) = .{ .handle = streams[i].parent, .flags = .{ .nonblocking = true } };
            streams[i].parent = -1;
        }
        if (streams[i].child >= 0) close(streams[i].child);
        streams[i].child = -1;
    }
    close(errors[1]);
    errors[1] = -1;
    var bytes: [2]u8 = undefined;
    var count: usize = 0;
    while (true) {
        try T.check(io, options.cancellation);
        if (T.expired(io, end)) return error.Timeout;
        const rc = linux.read(errors[0], bytes[count..].ptr, bytes.len - count);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    if (count != 0) return error.InvalidLaunchHandshake;
                    return child;
                }
                count += rc;
                if (count == bytes.len) return errnoError(@fromBackingInt(std.mem.readInt(u16, &bytes, .little)));
            },
            .INTR => continue,
            .AGAIN => try io.sleep(.fromMilliseconds(1), .awake),
            else => |err| return errnoError(err),
        }
    }
}

/// Borrowed readable-on-exit handle, valid until finish/deinit. Never close it.
pub fn pollHandle(self: *const Self) ?linux.fd_t {
    return self.pidfd;
}

/// Observe without reaping, closing pipes, or changing process-group lifetime.
pub fn poll(self: *Self) !?Term {
    if (self.term) |term| return term;
    const pid = self.pid orelse return error.Closed;
    var info = std.mem.zeroes(linux.siginfo_t);
    while (true) switch (linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null))) {
        .SUCCESS => break,
        .INTR => continue,
        .CHILD => return error.OwnershipLost,
        else => |err| return errnoError(err),
    };
    if (info.fields.common.first.piduid.pid == 0) return null;
    const status = info.fields.common.second.sigchld.status;
    return switch (@as(linux.CLD, @fromBackingInt(info.code))) {
        .EXITED => .{ .exited = @intCast(status) },
        .KILLED, .DUMPED => .{ .signal = @fromBackingInt(@intCast(status)) },
        else => error.UnexpectedWaitStatus,
    };
}

/// Wait up to timeout_ms for exit without reaping or terminating descendants.
/// Null means the interval elapsed. Zero performs one cancellation-aware poll.
pub fn pollFor(self: *Self, timeout_ms: u32) !?Term {
    return self.pollUntil(T.deadline(self.io, timeout_ms), null);
}

/// Observe until an absolute .awake deadline, sharing a budget with launch or
/// other work. Cancellation takes precedence over an observed exit. Even an
/// expired deadline checks status once. Neither timeout nor success consumes
/// ownership; finish/stop/deinit is still required. The token is borrowed only
/// for this call, independently of the token passed to spawn.
pub fn pollUntil(self: *Self, end: std.Io.Timestamp, cancellation: ?*const T.Cancellation) !?Term {
    while (true) {
        try T.check(self.io, cancellation);
        if (try self.poll()) |term| return term;
        if (T.expired(self.io, end)) return null;
        try self.io.sleep(.fromMilliseconds(1), .awake);
    }
}

pub fn signal(self: *Self, sig: linux.SIG) !void {
    const fd = self.pidfd orelse return error.Closed;
    const rc = linux.pidfd_send_signal(fd, sig, null, 0);
    if (linux.errno(rc) != .SRCH) try checked(rc);
    if (self.group == .owned) {
        const group_rc = linux.kill(-self.pid.?, sig);
        if (linux.errno(group_rc) != .SRCH) try checked(group_rc);
    }
}

/// Reap only after observed exit. Terminate group leftovers before releasing
/// the leader PID. Captured output pipes remain available until deinit.
pub fn finish(self: *Self) !Term {
    if (self.term) |term| return term;
    _ = try self.poll() orelse return error.StillRunning;
    if (self.group == .owned) try self.signal(.KILL);
    return self.reap();
}

/// Timeout/cancellation preserves the live owner and all its descriptors.
pub fn wait(self: *Self, timeout_ms: u32) !Term {
    return self.waitUntil(T.deadline(self.io, timeout_ms), null);
}

/// Like wait, using an absolute .awake deadline and an optional borrowed token.
/// Success finishes the child and cleans its owned group; timeout/cancellation
/// leaves ownership intact. Use pollUntil when descendants must keep running.
pub fn waitUntil(self: *Self, end: std.Io.Timestamp, cancellation: ?*const T.Cancellation) !Term {
    _ = try self.pollUntil(end, cancellation) orelse return error.Timeout;
    return self.finish();
}

/// Uncancelable TERM/grace/KILL cleanup. Joins the exact child before return.
pub fn stop(self: *Self, grace_ms: u32) !Term {
    if (self.term) |term| return term;
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    if (try self.poll() == null) {
        try self.signal(.TERM);
        const end = T.deadline(self.io, grace_ms);
        while (try self.poll() == null and !T.expired(self.io, end)) try self.io.sleep(.fromMilliseconds(1), .awake);
    }
    try self.signal(.KILL);
    return self.reap();
}

pub fn closeStdin(self: *Self) void {
    if (self.stdin) |file| close(file.handle);
    self.stdin = null;
}

/// Always call once per owner (repeat calls are safe). Cleanup uses no allocator
/// and never delegates force-kill semantics to std.process.Child.kill.
pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        // The unreaped PID is owned even if pidfd_open failed during setup.
        if (self.group == .owned) _ = linux.kill(-pid, .KILL);
        if (self.pidfd) |fd| {
            _ = linux.pidfd_send_signal(fd, .KILL, null, 0);
        } else _ = linux.kill(pid, .KILL);
        _ = self.reap() catch {};
    }
    if (self.pidfd) |fd| close(fd);
    self.pidfd = null;
    inline for (.{ "stdin", "stdout", "stderr" }) |name| {
        if (@field(self, name)) |file| close(file.handle);
        @field(self, name) = null;
    }
}

fn reap(self: *Self) !Term {
    var raw_status: i32 = 0;
    while (true) switch (linux.errno(linux.wait4(self.pid.?, &raw_status, 0, null))) {
        .SUCCESS => break,
        .INTR => continue,
        .CHILD => return error.OwnershipLost,
        else => |err| return errnoError(err),
    };
    const status: u32 = @bitCast(raw_status);
    self.term = if (linux.W.IFEXITED(status)) .{ .exited = linux.W.EXITSTATUS(status) } else if (linux.W.IFSIGNALED(status)) .{ .signal = linux.W.TERMSIG(status) } else .{ .unknown = status };
    self.pid = null;
    if (self.pidfd) |fd| close(fd);
    self.pidfd = null;
    return self.term.?;
}

const Prepared = struct {
    parent: linux.fd_t = -1,
    child: linux.fd_t = -1,
    fn deinit(self: *Prepared) void {
        if (self.parent >= 0) close(self.parent);
        if (self.child >= 0) close(self.child);
    }
    fn init(io: std.Io, stream: T.Stream, index: linux.fd_t) !Prepared {
        if (stream == .pipe) {
            const fds = try makePipe();
            var result: Prepared = .{ .parent = fds[if (index == 0) 1 else 0], .child = fds[if (index == 0) 0 else 1] };
            errdefer result.deinit();
            try nonblocking(result.parent);
            return result;
        }
        if (stream == .inherit) return .{ .child = try duplicate(index) };
        if (stream == .file) return .{ .child = try duplicate(stream.file.handle) };
        const file = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write });
        defer file.close(io);
        return .{ .child = try duplicate(file.handle) };
    }
};
fn makePipe() ![2]linux.fd_t {
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (fds) |fd| close(fd);
    const read_fd = try duplicate(fds[0]);
    errdefer close(read_fd);
    return .{ read_fd, try duplicate(fds[1]) };
}
fn duplicate(fd: linux.fd_t) !linux.fd_t {
    const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 3);
    try checked(rc);
    return @intCast(rc);
}
fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}
fn nonblocking(fd: linux.fd_t) !void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    try checked(flags);
    try checked(linux.fcntl(fd, linux.F.SETFL, flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
}
fn childMain(group: T.Group, cwd: linux.fd_t, streams: [3]Prepared, error_fd: linux.fd_t, paths: []const [:0]const u8, args: [:null]?[*:0]const u8, env: [:null]const ?[*:0]const u8) noreturn {
    if (group == .owned) childCheck(error_fd, linux.setpgid(0, 0));
    childCheck(error_fd, linux.fchdir(cwd));
    for (streams, 0..) |stream, i| childCheck(error_fd, linux.dup3(stream.child, @intCast(i), 0));
    childCheck(error_fd, linux.close_range(3, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = true }));
    const empty = linux.sigemptyset();
    const action: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = empty, .flags = 0 };
    for (1..linux.NSIG) |n| {
        const sig: linux.SIG = @fromBackingInt(@intCast(n));
        if (sig == .KILL or sig == .STOP) continue;
        childCheck(error_fd, linux.sigaction(sig, &action, null));
    }
    childCheck(error_fd, linux.sigprocmask(linux.SIG.SETMASK, &empty, null));
    var denied = false;
    for (paths) |path| {
        const err = linux.errno(linux.execve(path.ptr, args.ptr, env.ptr));
        switch (err) {
            .NOENT, .NOTDIR => {},
            .ACCES => denied = true,
            else => childFail(error_fd, err),
        }
    }
    childFail(error_fd, if (denied) .ACCES else .NOENT);
}
fn childCheck(fd: linux.fd_t, rc: usize) void {
    if (linux.errno(rc) != .SUCCESS) childFail(fd, linux.errno(rc));
}
fn childFail(fd: linux.fd_t, err: linux.E) noreturn {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, @intCast(@backingInt(err)), .little);
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                written += rc;
            },
            .INTR => continue,
            else => break,
        }
    }
    linux.exit_group(127);
}
fn checked(rc: usize) !void {
    if (linux.errno(rc) != .SUCCESS) return errnoError(linux.errno(rc));
}
fn errnoError(err: linux.E) anyerror {
    return switch (err) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOEXEC => error.InvalidExe,
        .NOTDIR => error.NotDir,
        .BADF => error.InvalidHandle,
        .TXTBSY => error.FileBusy,
        .NAMETOOLONG => error.NameTooLong,
        .LOOP, .IO => error.FileSystem,
        .AGAIN, .NOMEM, .@"2BIG" => error.SystemResources,
        .MFILE, .NFILE => error.FileDescriptorQuota,
        .NOSYS, .INVAL => error.OperationUnsupported,
        else => error.Unexpected,
    };
}
