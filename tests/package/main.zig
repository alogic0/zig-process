const std = @import("std");
const process = @import("process");
pub fn main(init: std.process.Init) !void {
    const result = try process.run(init.gpa, init.io, .{ .spawn = .{ .argv = &.{ "/bin/echo", "package-consumer" } } });
    defer result.deinit(init.gpa);
    if (!result.success() or !std.mem.eql(u8, result.stdout, "package-consumer\n")) return error.PackageConsumerFailed;
    const report: process.Report = try process.runReport(init.gpa, init.io, .{ .spawn = .{ .argv = &.{"/this-package-executable-does-not-exist"} } });
    defer report.deinit(init.gpa);
    if (report.outcome != .failed or report.outcome.failed.phase != .launch or report.outcome.failed.cause != error.FileNotFound or report.term != null or report.success()) return error.PackageReportFailed;
}
