# zig-process

Owned Linux child processes and bounded command capture for Zig **0.17.0**.
Standalone package, version 0.1.0, with no external dependencies.

Designed from Zeta, zg-backend and Paneva's process-management requirements.
See [DESIGN.md](DESIGN.md) for ownership decisions, source revisions and consumer
boundaries, and [CURRENT_STATUS.md](CURRENT_STATUS.md) for verification scope.

## Build and check

```sh
zig build
zig build test check
zig build test check -Doptimize=ReleaseSafe
zig build run-capture run-poll
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

Keep `spawn.stdout` and `spawn.stderr` at their default `.ignore` with `run`;
it installs its own pipes. Stdin can be ignored, inherited or a borrowed file.
For interactive stdin or other redirection, use `Child`.

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
| `pollHandle()` | Borrows a Linux pidfd for an event loop; never close it |
| `finish()` | Requires exit; kills owned group leftovers before reaping the exact leader |
| `wait(timeout_ms)` | Waits and finishes; timeout/cancellation leaves ownership intact |
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

## Cancellation and limits

Pass `.spawn.cancellation = &flag`, where `flag` is a `process.Cancellation`.
Another thread can call `flag.request()`. Keep it alive until the operation
returns and use a fresh flag for a new operation. `run` also honors std.Io task
cancellation. It cleans up its child before returning captures/errors.
`Child.wait` honors std.Io cancellation but preserves the caller's owner.

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

The three existing projects have not been migrated. This package's tests verify
its own contract; consumer adoption still needs each project's existing checks.
