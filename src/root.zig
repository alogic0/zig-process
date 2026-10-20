//! Explicit Linux process ownership for Zig 0.17.0. No application dependencies.
pub const Child = @import("child.zig");
pub const PipeReader = @import("pipe.zig").Reader;
pub const PipeWriter = @import("pipe.zig").Writer;
pub const SpawnOptions = @import("types.zig").SpawnOptions;
pub const Stream = @import("types.zig").Stream;
pub const Group = @import("types.zig").Group;
pub const Cancellation = @import("types.zig").Cancellation;
pub const RunOptions = @import("run.zig").Options;
pub const CaptureAllocation = @import("run.zig").CaptureAllocation;
pub const Result = @import("run.zig").Result;
pub const Outcome = @import("run.zig").Outcome;
pub const run = @import("run.zig").run;
pub const Report = @import("run.zig").Report;
pub const ReportOutcome = @import("run.zig").ReportOutcome;
pub const Failure = @import("run.zig").Failure;
pub const FailurePhase = @import("run.zig").FailurePhase;
pub const runReport = @import("run.zig").runReport;
