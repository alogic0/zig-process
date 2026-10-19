const std = @import("std");
const Child = @import("child.zig");
const T = @import("types.zig");
const linux = std.os.linux;

pub const Options = struct {
    spawn: T.SpawnOptions,
    timeout_ms: u32 = 30_000,
    stdout_limit: usize = 1024 * 1024,
    stderr_limit: usize = 1024 * 1024,
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

/// Captures both output streams. Spawn's stdout/stderr must be left at .ignore;
/// run owns those pipes. Use Child for custom output redirection or interactive stdin.
pub fn run(a: std.mem.Allocator, io: std.Io, options: Options) !Result {
    if (options.timeout_ms == 0 or options.spawn.launch_timeout_ms == 0 or options.spawn.stdin == .pipe or options.spawn.stdout != .ignore or options.spawn.stderr != .ignore or options.stdout_limit == std.math.maxInt(usize) or options.stderr_limit == std.math.maxInt(usize)) return error.InvalidOptions;
    const end = T.deadline(io, options.timeout_ms);
    const out = try a.alloc(u8, options.stdout_limit + 1);
    defer a.free(out);
    const err = try a.alloc(u8, options.stderr_limit + 1);
    defer a.free(err);
    var spawn = options.spawn;
    spawn.stdout = .pipe;
    spawn.stderr = .pipe;
    const launch_end = T.deadline(io, options.spawn.launch_timeout_ms);
    var child = try Child.spawnUntil(a, io, spawn, if (end.nanoseconds < launch_end.nanoseconds) end else launch_end);
    defer child.deinit();
    var capture = [_]Capture{ .{ .bytes = out }, .{ .bytes = err } };
    var outcome: Outcome = .completed;
    while (true) {
        T.check(io, spawn.cancellation) catch {
            outcome = .canceled;
            break;
        };
        if (T.expired(io, end)) {
            outcome = .timed_out;
            break;
        }
        const out_full = try capture[0].drain(child.stdout.?.handle);
        const err_full = try capture[1].drain(child.stderr.?.handle);
        if (out_full or err_full) {
            outcome = .output_limit;
            break;
        }
        if (try child.poll() != null) {
            _ = try child.finish();
            if (capture[0].eof and capture[1].eof) break;
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {
            outcome = .canceled;
            break;
        };
    }
    const term = if (child.term) |term| term else try child.stop(0);
    const stdout = try a.dupe(u8, out[0..@min(capture[0].len, options.stdout_limit)]);
    errdefer a.free(stdout);
    return .{ .outcome = outcome, .term = term, .stdout = stdout, .stderr = try a.dupe(u8, err[0..@min(capture[1].len, options.stderr_limit)]) };
}

const Capture = struct {
    bytes: []u8,
    len: usize = 0,
    eof: bool = false,
    fn drain(self: *Capture, fd: linux.fd_t) !bool {
        if (self.eof) return false;
        // Per-stream work is bounded even when a child continually refills it.
        for (0..16) |_| {
            const dest = self.bytes[self.len..@min(self.bytes.len, self.len +| 8192)];
            const rc = linux.read(fd, dest.ptr, dest.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) {
                        self.eof = true;
                        return false;
                    }
                    self.len += rc;
                    if (self.len == self.bytes.len) return true;
                },
                .AGAIN => return false,
                .INTR => continue,
                else => return error.CaptureReadFailed,
            }
        }
        return false;
    }
};
