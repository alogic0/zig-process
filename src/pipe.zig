//! Borrowed streaming interfaces for Child's nonblocking parent pipe ends.
//! Keep the Child and buffers alive until I/O has joined. These adapters never
//! close handles, finish children, or change descriptor/signal flags. Bound the
//! calling task with std.Io cancellation; framing belongs to the consumer.
const std = @import("std");
const Io = std.Io;

pub const Reader = struct {
    io: Io,
    file: Io.File,
    err: ?Io.File.Reader.Error = null,
    interface: Io.Reader,

    pub fn init(file: Io.File, io: Io, buffer: []u8) Reader {
        return .{ .file = file, .io = io, .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = self.read(dest) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => |cause| {
                self.err = cause;
                return error.ReadFailed;
            },
        };
        self.err = null;
        w.advance(n);
        return n;
    }

    fn read(self: *Reader, dest: []u8) Io.File.ReadStreamingError!usize {
        while (true) {
            try self.io.checkCancel();
            return self.file.readStreaming(self.io, &.{dest}) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.io.sleep(.fromMilliseconds(1), .awake);
                    continue;
                },
                else => return err,
            };
        }
    }
};

pub const Writer = struct {
    io: Io,
    file: Io.File,
    err: ?Io.File.Writer.Error = null,
    interface: Io.Writer,

    pub fn init(file: Io.File, io: Io, buffer: []u8) Writer {
        return .{ .file = file, .io = io, .interface = .{
            .vtable = &.{ .drain = drain },
            .buffer = buffer,
        } };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        const n = self.write(data, splat) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        self.err = null;
        return w.consume(n);
    }

    fn write(self: *Writer, data: []const []const u8, splat: usize) Io.File.Writer.Error!usize {
        while (true) {
            try self.io.checkCancel();
            return self.file.writeStreaming(self.io, self.interface.buffered(), data, splat) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.io.sleep(.fromMilliseconds(1), .awake);
                    continue;
                },
                else => return err,
            };
        }
    }
};
