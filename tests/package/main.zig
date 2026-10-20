const std = @import("std");
const process = @import("process");
pub fn main(init: std.process.Init) !void {
    for ([_]process.CaptureAllocation{ .grow, .preallocate }) |allocation| {
        const result = try process.run(init.gpa, init.io, .{
            .spawn = .{ .argv = &.{ "/bin/echo", "package-consumer" } },
            .capture_allocation = allocation,
            .stdout_limit = 4096,
            .stderr_limit = 4096,
        });
        defer result.deinit(init.gpa);
        if (!result.success() or !std.mem.eql(u8, result.stdout, "package-consumer\n")) return error.PackageConsumerFailed;
    }
    const report: process.Report = try process.runReport(init.gpa, init.io, .{ .spawn = .{ .argv = &.{"/this-package-executable-does-not-exist"} } });
    defer report.deinit(init.gpa);
    if (report.outcome != .failed or report.outcome.failed.phase != .launch or report.outcome.failed.cause != error.FileNotFound or report.term != null or report.success()) return error.PackageReportFailed;
    const end = std.Io.Clock.awake.now(init.io).addDuration(.fromSeconds(3));
    var child = try process.Child.spawnUntil(init.gpa, init.io, .{ .argv = &.{"/bin/true"} }, end);
    defer child.deinit();
    const pid = child.pid.?;
    const term = try child.pollUntil(end, null) orelse return error.PackageExitDeadline;
    if (!term.success() or child.pid != pid or !(try child.pollFor(0)).?.success()) return error.PackageObservationFailed;
    var flag: process.Cancellation = .{};
    flag.request();
    if (child.waitUntil(end, &flag)) |_| return error.PackageCancellationFailed else |err| if (err != error.Canceled) return err;
    if (!(try child.waitUntil(end, null)).success() or child.pid != null) return error.PackageWaitFailed;
    var echo = try process.Child.spawn(init.gpa, init.io, .{ .argv = &.{"/bin/cat"}, .stdin = .pipe, .stdout = .pipe });
    defer echo.deinit();
    var rb: [16]u8 = undefined;
    var wb: [16]u8 = undefined;
    var reader = process.PipeReader.init(echo.stdout.?, init.io, &rb);
    var writer = process.PipeWriter.init(echo.stdin.?, init.io, &wb);
    try writer.interface.writeAll("package\x00");
    try writer.interface.flush();
    echo.closeStdin();
    var bytes: [8]u8 = undefined;
    try reader.interface.readSliceAll(&bytes);
    if (!std.mem.eql(u8, &bytes, "package\x00")) return error.PackagePipeFailed;
    if (reader.interface.takeByte()) |_| return error.PackageEofFailed else |err| if (err != error.EndOfStream) return err;
    if (!(try echo.wait(3000)).success()) return error.PackagePipeExitFailed;
}
