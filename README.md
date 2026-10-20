# zig-process

Owned Linux child processes and bounded command capture for Zig **0.17.0**.
Standalone package, version 0.3.0, with no external dependencies.

Designed from Zeta, zg-backend and Paneva's process-management requirements.
See [DESIGN.md](DESIGN.md) for ownership decisions, source revisions and consumer
boundaries, and [CURRENT_STATUS.md](CURRENT_STATUS.md) for verification scope.

## Build and check

```sh
zig build
zig build test check
zig build test check -Doptimize=ReleaseSafe
zig build run-capture run-poll run-lifecycle
./zig-out/bin/process-capture /bin/echo hello
cd tests/package
zig build test
```

Builds require exactly Zig 0.17.0. Tests use native fixture executables and
ordinary local processes; no database, browser, service or desktop session is
started. Optional `-Dtest-filter=substring` selects matching tests.

## Use as a package

For a sibling project, add to its `build.zig.zon` dependencies:

```zig
.process = .{ .path = "../zig-process" },
```

Then add the module to the consuming executable/library:

```zig
const process = b.dependency("process", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("process", process.module("process"));
```

The [capture example](examples/capture.zig) is a complete compilable caller:

```zig
const process = @import("process");

const result = try process.run(allocator, io, .{
    .spawn = .{
        .argv = &.{ "/usr/bin/git", "status", "--short" },
        .cwd = .{ .path = "/path/to/repository" },
    },
    .timeout_ms = 10_000,
    .stdout_limit = 1024 * 1024,
    .stderr_limit = 64 * 1024,
});
defer result.deinit(allocator);
if (!result.success()) {
    // Inspect outcome, actual term, stdout and stderr before deciding policy.
}
```

`run` captures both streams concurrently using bounded nonblocking reads. It
never invokes a shell implicitly. PATH lookup is off by default; enable
`.search_path = true` for bare command names. An explicit `.environ_map` replaces
inheritance and supplies the PATH used for lookup. Arguments/output may contain
arbitrary bytes, except argv/environment strings cannot contain NUL.

`outcome` is `completed`, `timed_out`, `canceled` or `output_limit`. `term` retains
the actual exit code/signal, including termination used for cleanup. Only
`completed` with exit zero is `success()`. Setup/exec/I/O/OOM failures return
errors; a launch timeout or pre-launch cancellation also returns an error.
After launch, interrupted results own bounded partial output. Deinit each Result
exactly once. Neither output exceeds its configured limit.

Use a reclaiming allocator for repeated `run` calls. A long-lived arena retains
temporary capture buffers until it is reset, even after Result.deinit.

By default, leader exit terminates the owned group before draining its remaining
buffered output. Set `.exit_policy = .drain_output` to allow descendants to finish
writing until both streams reach EOF. The leader stays unreaped until then;
the same deadline, cancellation and output limits still apply. A held-open pipe
times out and triggers group cleanup, retaining the leader's original exit status.

Keep `spawn.stdout` and `spawn.stderr` at their default `.ignore` with `run`;
it installs its own pipes. Stdin can be ignored, inherited or a borrowed file.
For interactive stdin or other redirection, use `Child`.

## Partial output on failure

Use `runReport` when diagnostics must survive launch or supervision errors:

```zig
const report = try process.runReport(allocator, io, .{
    .spawn = .{ .argv = &.{ "/path/to/command", "argument" } },
    .timeout_ms = 10_000,
    .stdout_limit = 1024 * 1024,
    .stderr_limit = 64 * 1024,
});
defer report.deinit(allocator);

switch (report.outcome) {
    .failed => |failure| {
        // failure.phase: launch, stdout, stderr, poll, or finish.
        // failure.cause: the original error.
        // report.stdout and report.stderr retain already captured bytes.
        _ = failure;
    },
    else => {},
}
```

`ReportOutcome` has the four ordinary outcomes plus `failed: Failure`. Launch
failures, including pre-launch cancellation/timeout, carry phase `launch` and no
termination. Post-launch failures retain bounded captured output and any known
observed/cleanup termination. `term` is optional; an unavailable status is null.
Only completed exit zero with no cleanup failure is `success()`.

`cleanup_failure` records an error from stopping the child without replacing the
primary outcome or failure. Final force cleanup and descriptor closure are still
attempted before returning. `deinit` releases both output buffers exactly once.
Invalid options and allocation failures return errors; OOM cannot promise a
report. Output ownership transfers only when `runReport` returns successfully.

Both APIs share the same capture and child ownership implementation. `run`
continues to return launch/supervision failures as errors; choose `runReport`
when their partial output is needed.

## Long-lived children and UI polling

```zig
var child = try process.Child.spawn(allocator, io, .{
    .argv = &.{ "/path/to/application" },
    .stdout = .{ .file = log_file },
    .stderr = .{ .file = log_file },
});
defer child.deinit();

if (try child.poll()) |_| {
    const term = try child.finish();
    // Update application state from term.
}
```

| Operation | Ownership/result |
| --- | --- |
| `Child.spawn` | Returns one owner after exec acknowledgement; launch failure cleans up |
| `poll()` | Returns null or observed termination; does not reap |
| `pollFor(timeout_ms)` | Waits for exit without reaping; null on elapsed interval |
| `pollUntil(deadline, cancellation)` | Same observation using an absolute `.awake` deadline and optional token |
| `pollHandle()` | Borrows a Linux pidfd for an event loop; never close it |
| `finish()` | Requires exit; kills owned group leftovers before reaping the exact leader |
| `wait(timeout_ms)` | Waits and finishes; timeout/cancellation leaves ownership intact |
| `waitUntil(deadline, cancellation)` | Waits and finishes within a shared deadline; timeout/cancellation leaves ownership intact |
| `signal(sig)` | Signals the exact child and, in owned-group mode, its group |
| `stop(grace_ms)` | Uncancelable TERM, grace, KILL and exact-child join |
| `closeStdin()` | Closes only the parent's stdin pipe end |
| `deinit()` | Immediate force cleanup and descriptor closure; repeat calls are safe |

The default `.group = .owned` creates a new process group. Finishing the leader
terminates remaining members before releasing its PID. Use `.child_only` when
only the direct child is yours to terminate. No group signals occur after reaping.
Pipes remain available after finish/wait until deinit, so buffered output can be
drained. Always drain piped output while the child runs; `wait` does not capture
and a full undrained pipe can prevent child exit.

Parent pipe handles are nonblocking; child ends are blocking. Files supplied
through `.file` remain borrowed and retain their original blocking mode. Streams
default to `/dev/null`. `.inherit` on an already closed standard descriptor fails.
Only standard streams are inherited; extra parent descriptors are CLOEXEC in the
child. Child signal dispositions and mask are reset before exec.

## Backend process owners

The [lifecycle example](examples/lifecycle.zig) is a compiled and runnable example
of a log-backed child with a single budget covering launch and exit observation.
`pollFor(0)` checks immediately. `pollUntil` also checks once when its deadline
has expired: an observable exit wins over timeout. Cancellation is checked first
and returns `error.Canceled`, even when exit is observable. Neither observation
method closes pipes, reaps the leader, or signals descendants.

```zig
const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(15));
var child = try process.Child.spawnUntil(allocator, io, options, deadline);
defer child.deinit();

const term = try child.pollUntil(deadline, &cancel) orelse return error.ExitTimeout;
// Observe application resources while the PID/group is still reserved.
// Use term for status; keep JSON and negative-signal-code mapping in the caller.
_ = term;
_ = try child.finish();
```

For `zg-backend`'s `import_browser_runtime.Owned` at baseline `417baee3`:

| Existing mechanism | Integration path |
| --- | --- |
| `std.process.spawn` with a new group and log files | `Child.spawn`; the default is an owned group; log files remain borrowed |
| `poll(io, ms)` and its local `waitid` loop | `pollFor(ms)`, mapping `Term` to the existing status representation |
| Status followed by browser-profile discovery and stop | Observe without finishing; discover owned profiles before `stop` |
| TERM/grace/KILL and exact-child wait | `stop(grace_ms)`; always also defer `deinit` for descriptors and error paths |
| A deadline spanning launch and other work | `spawnUntil` plus `pollUntil` or `waitUntil`, sharing one `.awake` timestamp |

The backend currently reaps in its local status method. The proposed replacement
deliberately keeps an exited leader unreaped until explicit finish/stop/deinit,
preventing its PID/group identity from being reused before group cleanup.
Retain backend process IDs and status mapping, but never signal a cached OS PID
after ownership ends. Keep log closure, browser profiles, readiness, protocol
framing, containers, database cleanup and evidence policy in the backend.
Existing command callers can keep `runReport`; they need no changes.

These APIs make migration possible without duplicating timed polling. Actual
backend migration still needs its lifecycle/protocol/profile tests; this release
changes only the library. Piped output must still be drained concurrently, and
parent pipe ends remain nonblocking.

## Cancellation and limits

Pass `.spawn.cancellation = &flag`, where `flag` is a `process.Cancellation`.
Another thread can call `flag.request()`. Keep it alive until the operation
returns and use a fresh flag for a new operation. `run` also honors std.Io task
cancellation. It cleans up its child before returning captures/errors.
`Child.wait` and `pollFor` honor std.Io cancellation but preserve the caller's
owner. `pollUntil` and `waitUntil` additionally accept a per-call cancellation
token. That token is borrowed only until the call returns, and is independent
of the token passed to spawn; Child retains neither token. After cancellation,
the same child may be observed/waited using a fresh token, or stopped. Cleanup
through `stop`/`deinit` remains uncancelable.

Live Child values must not be copied or concurrently operated on. Each owner
supports independent concurrent siblings; allocator thread safety remains the
caller's responsibility. Do not externally reap library-owned PIDs. Hosts with
SIGCHLD ignored or SA_NOCLDWAIT are rejected, and global reapers must exclude
these children. The library installs no parent signal handlers or subreaper state.

v0.1 supports Linux with pidfd and close_range(CLOEXEC), and std.Io.Threaded.
Verification is on x86_64 Linux; other architectures have not been validated.
Group cleanup does not contain descendants that deliberately change groups or
sessions, and cannot reap grandchildren. Paneva's dedicated subreaper logic
therefore remains a separate integration concern. A stuck kernel task can delay
cleanup even after KILL. Windows/macOS, extra inherited descriptors, privilege
changes, restart policies and a dedicated supervisor executable are outside v0.1.

Backend commands and several owners already use v0.2; its older import owner
remains local at the inspected baseline. This package's tests verify its own
contract; further consumer adoption still needs each project's existing checks.
