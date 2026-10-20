const std = @import("std");
const Child = @import("child.zig");
const T = @import("types.zig");
const linux = std.os.linux;

pub const CaptureAllocation = enum { grow, preallocate };
pub const Options = struct {
    spawn: T.SpawnOptions,
    timeout_ms: u32 = 30_000,
    stdout_limit: usize = 1024 * 1024,
    stderr_limit: usize = 1024 * 1024,
    /// Grow with actual output, or reserve both capture limits before launch.
    /// Limits remain hard bounds in either mode. Results are allocated separately.
    capture_allocation: CaptureAllocation = .grow,
    /// Keep the exited leader owned while descendants finish writing. The same
    /// deadline, cancellation and output limits still bound draining.
    exit_policy: enum { terminate_group, drain_output } = .terminate_group,
};
pub const Outcome = enum { completed, timed_out, canceled, output_limit };
pub const Result = struct {
    outcome: Outcome,
    /// Actual termination, including the signal used to clean up an interrupted command.
    term: Child.Term,
    stdout: []u8,
    stderr: []u8,
    pub fn success(self: Result) bool {
        return self.outcome == .completed and self.term.success();
    }
    pub fn deinit(self: Result, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

pub const FailurePhase = enum { launch, stdout, stderr, poll, finish };
pub const Failure = struct { phase: FailurePhase, cause: anyerror };
pub const ReportOutcome = union(enum) {
    completed,
    timed_out,
    canceled,
    output_limit,
    failed: Failure,
};

/// Owns bounded output even when launch or supervision fails. Deinit exactly
/// once. A cleanup error is secondary to the original outcome/failure.
pub const Report = struct {
    outcome: ReportOutcome,
    /// Observed or cleanup termination; null when unavailable or launch failed.
    term: ?Child.Term,
    stdout: []u8,
    stderr: []u8,
    cleanup_failure: ?anyerror = null,

    pub fn success(self: Report) bool {
        return self.outcome == .completed and self.cleanup_failure == null and
            if (self.term) |term| term.success() else false;
    }
    pub fn deinit(self: Report, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

/// Captures both output streams. Spawn's stdout/stderr must be left at .ignore;
/// run owns those pipes. Use Child for custom output redirection or interactive stdin.
pub fn run(a: std.mem.Allocator, io: std.Io, options: Options) !Result {
    var system: System = .{};
    const captured = try captureWith(a, io, options, &system);
    defer captured.deinit(a);
    // Preserve returned errors without allocating output copies on this path.
    const outcome: Outcome = switch (captured.outcome) {
        .completed => .completed,
        .timed_out => .timed_out,
        .canceled => .canceled,
        .output_limit => .output_limit,
        .failed => |failure| return failure.cause,
    };
    if (captured.cleanup_failure) |err| return err;
    const output = try captured.copyOutput(a);
    return .{ .outcome = outcome, .term = captured.term.?, .stdout = output[0], .stderr = output[1] };
}

/// Reports launch/supervision failures with owned partial output. Invalid options
/// and allocation failures remain returned errors. Child cleanup precedes return.
pub fn runReport(a: std.mem.Allocator, io: std.Io, options: Options) !Report {
    var system: System = .{};
    return reportWith(a, io, options, &system);
}

fn reportWith(a: std.mem.Allocator, io: std.Io, options: Options, ops: anytype) !Report {
    const captured = try captureWith(a, io, options, ops);
    defer captured.deinit(a);
    const output = try captured.copyOutput(a);
    return .{ .outcome = captured.outcome, .term = captured.term, .stdout = output[0], .stderr = output[1], .cleanup_failure = captured.cleanup_failure };
}

const Captured = struct {
    streams: [2]Capture,
    outcome: ReportOutcome = .completed,
    term: ?Child.Term = null,
    cleanup_failure: ?anyerror = null,

    fn fail(self: *Captured, phase: FailurePhase, cause: anyerror) void {
        self.outcome = .{ .failed = .{ .phase = phase, .cause = cause } };
    }
    fn deinit(self: Captured, a: std.mem.Allocator) void {
        for (self.streams) |stream| a.free(stream.bytes);
    }
    fn copyOutput(self: Captured, a: std.mem.Allocator) ![2][]u8 {
        const stdout = try a.dupe(u8, self.streams[0].bytes[0..self.streams[0].len]);
        errdefer a.free(stdout);
        return .{ stdout, try a.dupe(u8, self.streams[1].bytes[0..self.streams[1].len]) };
    }
};

fn captureWith(a: std.mem.Allocator, io: std.Io, options: Options, ops: anytype) !Captured {
    if (options.timeout_ms == 0 or options.spawn.launch_timeout_ms == 0 or options.spawn.stdin == .pipe or options.spawn.stdout != .ignore or options.spawn.stderr != .ignore or options.stdout_limit == std.math.maxInt(usize) or options.stderr_limit == std.math.maxInt(usize)) return error.InvalidOptions;
    const end = T.deadline(io, options.timeout_ms);
    var captured: Captured = .{ .streams = .{ .{ .limit = options.stdout_limit }, .{ .limit = options.stderr_limit } } };
    errdefer captured.deinit(a);
    if (options.capture_allocation == .preallocate) {
        for (&captured.streams) |*stream| stream.bytes = try a.alloc(u8, stream.limit);
    }
    var spawn = options.spawn;
    spawn.stdout = .pipe;
    spawn.stderr = .pipe;
    const launch_end = T.deadline(io, options.spawn.launch_timeout_ms);
    var child = Child.spawnUntil(a, io, spawn, if (end.nanoseconds < launch_end.nanoseconds) end else launch_end) catch |cause| {
        if (cause == error.OutOfMemory or cause == error.InvalidOptions) return cause;
        captured.fail(.launch, cause);
        return captured;
    };
    defer child.deinit();
    capture: while (true) {
        T.check(io, spawn.cancellation) catch {
            captured.outcome = .canceled;
            break;
        };
        if (T.expired(io, end)) {
            captured.outcome = .timed_out;
            break;
        }
        const out_full = captured.streams[0].drain(a, child.stdout.?.handle, ops) catch |cause| {
            if (cause == error.OutOfMemory) return cause;
            captured.fail(.stdout, cause);
            break;
        };
        const err_full = captured.streams[1].drain(a, child.stderr.?.handle, ops) catch |cause| {
            if (cause == error.OutOfMemory) return cause;
            captured.fail(.stderr, cause);
            break;
        };
        if (out_full or err_full) {
            captured.outcome = .output_limit;
            break;
        }
        if (ops.poll(&child) catch |cause| {
            captured.fail(.poll, cause);
            break;
        }) |term| {
            captured.term = term;
            if (options.exit_policy == .terminate_group or (captured.streams[0].eof and captured.streams[1].eof)) {
                _ = ops.finish(&child) catch |cause| {
                    captured.fail(.finish, cause);
                    break :capture;
                };
            }
            if (captured.streams[0].eof and captured.streams[1].eof) break;
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {
            captured.outcome = .canceled;
            break;
        };
    }
    if (child.term == null) {
        if (ops.stop(&child)) |_| {} else |cause| {
            captured.cleanup_failure = cause;
        }
    }
    // Final cleanup also handles a failed stop. Do it before allocating report
    // copies so OOM cannot skip child teardown; deinit is safely repeatable.
    child.deinit();
    if (child.term) |term| captured.term = term;
    return captured;
}

const Read = union(enum) { bytes: usize, again, interrupted };
const System = struct {
    fn read(_: *System, fd: linux.fd_t, dest: []u8) !Read {
        const rc = linux.read(fd, dest.ptr, dest.len);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .bytes = rc },
            .AGAIN => .again,
            .INTR => .interrupted,
            else => error.CaptureReadFailed,
        };
    }
    fn poll(_: *System, child: *Child) !?Child.Term {
        return child.poll();
    }
    fn finish(_: *System, child: *Child) !Child.Term {
        return child.finish();
    }
    fn stop(_: *System, child: *Child) !Child.Term {
        return child.stop(0);
    }
};

const Capture = struct {
    bytes: []u8 = &.{},
    limit: usize,
    len: usize = 0,
    eof: bool = false,
    fn drain(self: *Capture, a: std.mem.Allocator, fd: linux.fd_t, ops: anytype) !bool {
        if (self.eof) return false;
        // Read before growing: empty streams and repeated AGAIN/EOF do not
        // allocate. One extra byte detects overflow without retaining it.
        var buffer: [8192]u8 = undefined;
        // Per-stream work is bounded even when a child continually refills it.
        for (0..16) |_| {
            const remaining = self.limit - self.len;
            switch (try ops.read(fd, buffer[0..@min(buffer.len, remaining + 1)])) {
                .bytes => |n| {
                    if (n == 0) {
                        self.eof = true;
                        return false;
                    }
                    const kept = @min(n, remaining);
                    const required = self.len + kept;
                    if (required > self.bytes.len) {
                        const grown = @max(@as(usize, 8192), self.bytes.len +| (self.bytes.len / 2));
                        self.bytes = try a.realloc(self.bytes, @min(self.limit, @max(required, grown)));
                    }
                    @memcpy(self.bytes[self.len..required], buffer[0..kept]);
                    self.len = required;
                    if (n > remaining) return true;
                },
                .again => return false,
                .interrupted => continue,
            }
        }
        return false;
    }
};

// Unit-only operation substitution keeps deterministic failures out of the public
// API. Real children/pipes are still used and cleaned by the production owner.
const Faults = struct {
    phase: FailurePhase,
    fail_cleanup: bool = false,
    system: System = .{},
    stdout_fd: ?linux.fd_t = null,
    lengths: [2]usize = .{ 0, 0 },
    pid: ?linux.pid_t = null,

    fn ready(self: *const Faults) bool {
        return self.lengths[0] == 5 and self.lengths[1] == 4 and self.pid != null;
    }
    fn cause(self: *const Faults) anyerror {
        return switch (self.phase) {
            .stdout => error.InjectedStdoutFailure,
            .stderr => error.InjectedStderrFailure,
            .poll => error.InjectedPollFailure,
            .finish => error.InjectedFinishFailure,
            .launch => unreachable,
        };
    }
    fn read(self: *Faults, fd: linux.fd_t, dest: []u8) !Read {
        if (self.stdout_fd == null) self.stdout_fd = fd;
        const index: usize = if (fd == self.stdout_fd.?) 0 else 1;
        if (self.ready() and self.phase == (if (index == 0) FailurePhase.stdout else .stderr)) return self.cause();
        const result = try self.system.read(fd, dest);
        if (result == .bytes) self.lengths[index] += result.bytes;
        return result;
    }
    fn poll(self: *Faults, child: *Child) !?Child.Term {
        if (child.pid) |pid| self.pid = pid;
        if (self.ready() and self.phase == .poll) return self.cause();
        return self.system.poll(child);
    }
    fn finish(self: *Faults, child: *Child) !Child.Term {
        if (self.ready() and self.phase == .finish) return self.cause();
        return self.system.finish(child);
    }
    fn stop(self: *Faults, child: *Child) !Child.Term {
        if (self.fail_cleanup) return error.InjectedCleanupFailure;
        return self.system.stop(child);
    }
};

fn faultReport(a: std.mem.Allocator, faults: *Faults) !Report {
    const config = @import("test_options");
    const fixture = if (std.fs.path.isAbsolute(config.fixture)) config.fixture else config.workspace_root ++ "/" ++ config.fixture;
    const argv = [_][]const u8{ fixture, "report", if (faults.phase == .finish) "exit" else "wait" };
    return reportWith(a, std.testing.io, .{
        .spawn = .{ .argv = &argv },
        .timeout_ms = 3000,
        .stdout_limit = 5,
        .stderr_limit = 4,
    }, faults);
}

fn expectReaped(pid: linux.pid_t) !void {
    try std.testing.expectEqual(linux.E.SRCH, linux.errno(linux.kill(pid, @fromBackingInt(0))));
    var status: i32 = 0;
    try std.testing.expectEqual(linux.E.CHILD, linux.errno(linux.wait4(pid, &status, linux.W.NOHANG, null)));
}

fn fdCount() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io) != null) count += 1;
    return count;
}

test "report retains both binary streams and original capture observation finish failures" {
    const before = try fdCount();
    for ([_]FailurePhase{ .stdout, .stderr, .poll, .finish }) |phase| {
        var faults: Faults = .{ .phase = phase };
        const report = try faultReport(std.testing.allocator, &faults);
        defer report.deinit(std.testing.allocator);
        try std.testing.expectEqual(phase, report.outcome.failed.phase);
        try std.testing.expectEqual(faults.cause(), report.outcome.failed.cause);
        try std.testing.expectEqualStrings("out\x00\xff", report.stdout);
        try std.testing.expectEqualStrings("err\xfe", report.stderr);
        try std.testing.expect(report.cleanup_failure == null);
        try std.testing.expect(report.term != null);
        if (phase == .finish) try std.testing.expectEqual(@as(u8, 7), report.term.?.exited);
        try std.testing.expect(!report.success());
        try expectReaped(faults.pid.?);
    }
    try std.testing.expectEqual(before, try fdCount());
}

test "report preserves primary error when stop fails and final teardown still joins" {
    const before = try fdCount();
    var faults: Faults = .{ .phase = .stdout, .fail_cleanup = true };
    const report = try faultReport(std.testing.allocator, &faults);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(error.InjectedStdoutFailure, report.outcome.failed.cause);
    try std.testing.expectEqual(@as(?anyerror, error.InjectedCleanupFailure), report.cleanup_failure);
    try std.testing.expectEqualStrings("out\x00\xff", report.stdout);
    try std.testing.expectEqualStrings("err\xfe", report.stderr);
    try std.testing.expectEqual(linux.SIG.KILL, report.term.?.signal);
    try std.testing.expect(!report.success());
    try expectReaped(faults.pid.?);
    try std.testing.expectEqual(before, try fdCount());
}

const NonResizing = struct {
    parent: std.mem.Allocator,
    fn allocator(self: *NonResizing) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *NonResizing = @ptrCast(@alignCast(ptr));
        return self.parent.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *NonResizing = @ptrCast(@alignCast(ptr));
        self.parent.rawFree(memory, alignment, ra);
    }
};

fn allocationCase(a: std.mem.Allocator) !void {
    var fixed: NonResizing = .{ .parent = a };
    const allocator = fixed.allocator();
    var faults: Faults = .{ .phase = .stdout };
    const report = faultReport(allocator, &faults) catch |err| {
        if (faults.pid) |pid| try expectReaped(pid);
        return err;
    };
    defer report.deinit(allocator);
    try expectReaped(faults.pid.?);
    try std.testing.expectEqual(error.InjectedStdoutFailure, report.outcome.failed.cause);
}

test "report allocation failure after partial capture leaves no owned child or descriptor" {
    try allocationCase(std.testing.allocator);
    const before = try fdCount();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
    try std.testing.expectEqual(before, try fdCount());
}

// Fail a real buffer growth only after a real child has supplied more than one
// chunk on the selected stream. Launch allocations cannot trigger this control.
const GrowthOom = struct {
    stream: usize,
    stdout_fd: ?linux.fd_t = null,
    lengths: [2]usize = .{ 0, 0 },
    armed: bool = false,
    failed: bool = false,
    system: System = .{},

    fn allocator(self: *GrowthOom) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *GrowthOom = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.failed = true;
            return null;
        }
        return std.testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
    fn read(self: *GrowthOom, fd: linux.fd_t, dest: []u8) !Read {
        if (self.stdout_fd == null) self.stdout_fd = fd;
        const index: usize = if (fd == self.stdout_fd.?) 0 else 1;
        const result = try self.system.read(fd, dest);
        if (result == .bytes) self.lengths[index] += result.bytes;
        self.armed = self.lengths[self.stream] > 8192;
        return result;
    }
    fn poll(self: *GrowthOom, child: *Child) !?Child.Term {
        return self.system.poll(child);
    }
    fn finish(self: *GrowthOom, child: *Child) !Child.Term {
        return self.system.finish(child);
    }
    fn stop(self: *GrowthOom, child: *Child) !Child.Term {
        return self.system.stop(child);
    }
};

fn ownedChildren() ![]u8 {
    var buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "/proc/self/task/{d}/children", .{linux.gettid()});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(65536));
}

test "allocation failure while growing either live stream reaps child and closes descriptors" {
    const config = @import("test_options");
    const fixture = if (std.fs.path.isAbsolute(config.fixture)) config.fixture else config.workspace_root ++ "/" ++ config.fixture;
    const before_fds = try fdCount();
    const before_children = try ownedChildren();
    defer std.testing.allocator.free(before_children);
    for (0..2) |index| {
        var faults: GrowthOom = .{ .stream = index };
        try std.testing.expectError(error.OutOfMemory, reportWith(faults.allocator(), std.testing.io, .{
            .spawn = .{ .argv = &.{ fixture, "exact", "200000" } },
        }, &faults));
        try std.testing.expect(faults.failed);
        try std.testing.expect(faults.lengths[index] > 8192);
        try std.testing.expectEqual(before_fds, try fdCount());
        const after_children = try ownedChildren();
        defer std.testing.allocator.free(after_children);
        try std.testing.expectEqualStrings(before_children, after_children);
    }
}
