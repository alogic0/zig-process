const std = @import("std");

/// A one-way flag. It may be requested from another thread. Keep it alive until
/// all borrowers return; use a fresh flag for a new operation.
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    pub fn isRequested(self: *const Cancellation) bool {
        return self.requested.load(.acquire);
    }
};

pub const Stream = union(enum) { ignore, inherit, pipe, file: std.Io.File };
pub const Group = enum { child_only, owned };
pub const SpawnOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    /// Search the child's PATH only when argv[0] has no slash.
    search_path: bool = false,
    /// Legacy std.process.spawn callers search the parent's PATH even with an
    /// explicit child environment. Only affects lookup, not the child env.
    search_path_environment: enum { child, parent } = .child,
    stdin: Stream = .ignore,
    stdout: Stream = .ignore,
    stderr: Stream = .ignore,
    group: Group = .owned,
    launch_timeout_ms: u32 = 30_000,
    cancellation: ?*const Cancellation = null,
};

pub fn check(io: std.Io, cancellation: ?*const Cancellation) error{Canceled}!void {
    if (cancellation) |c| if (c.isRequested()) return error.Canceled;
    try io.checkCancel();
}
pub fn deadline(io: std.Io, ms: u32) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(ms));
}
pub fn expired(io: std.Io, end: std.Io.Timestamp) bool {
    return std.Io.Clock.awake.now(io).nanoseconds >= end.nanoseconds;
}
