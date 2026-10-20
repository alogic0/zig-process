# zig-process design

## Purpose and bounded delivery

Provide reusable process ownership for Zeta commands, backend acceptance fixtures,
and Paneva applications/services. The backend benefit is reliable import/recovery
verification: canceled runs release their processes, and failed commands retain
honest results. Paneva needs responsive UI polling; Zeta needs bounded captures
and cancellation without interpreter dependencies.

This initial delivery is a Linux Zig 0.17.0 library, tests, examples and integration
guidance. It does not migrate consumers. Completion requires the finite cases in
CURRENT_STATUS.md, Debug/ReleaseSafe checks, and committed standalone sources.

## Public layers

1. `Child`: launch with explicit argv, cwd, environment, executable lookup and
   stream redirection; observe exit without consuming it; signal, wait, stop,
   and destroy the exact owned child. A borrowed pidfd supports external poll loops.
2. `run`: simultaneous bounded stdout/stderr capture with a deadline covering
   launch and execution, an optional cancellation flag, and typed outcomes.
3. A dedicated descendant supervisor is a future, separately executable layer.
   The embedded library never enables subreaping or calls `waitpid(-1)`.

`Child` and its handles are move-only by convention and confined to one owner.
The caller must not copy a live owner, close borrowed handles, or reap its PID.
Concurrent independent owners are supported. Allocator and std.Io are explicit.
The only cross-thread mutable control is the atomic cancellation flag.

## Lifecycle and process groups

`spawn -> live -> observed exit -> finish -> reaped -> deinit`.

`poll` uses waitid with WNOWAIT. An observed leader remains unreaped, reserving its
PID and process-group identity. `finish` requires observed exit, signals KILL to
the owned group before reaping the exact leader, and retains capture descriptors
until deinit. Repeated finish/wait returns the saved termination status.

Group mode defaults to a new owned process group. Child-only mode leaves group
membership unchanged and signals only the owned child. No group signal is issued
after reaping. `stop` sends TERM, allows a caller-specified grace interval, then
KILL and joins. `deinit` force-cleans immediately and is idempotent. Cleanup is
uncancelable and allocates nothing. Wait timeouts leave ownership intact.

Group cleanup kills ordinary descendants but cannot reap grandchildren, or
contain descendants which deliberately change group/session. Those require the
separate supervisor or an external containment facility. Kernel tasks stuck in
uninterruptible sleep can delay joining even after KILL; deadlines bound normal
operation, not an unconditional wall-clock guarantee for kernel cleanup.

## Launch contract

Use an owned fork/exec handshake adapted from Zeta's launcher. Installed Zig
0.17.0 `processSpawnPosix` returns a failed-exec error without reclaiming the
returned PID/pipes, so simply wrapping it would preserve an ownership hole.
All allocation and string construction occur before fork. Child setup uses Linux
syscalls only. The parent owns the child before waiting for exec acknowledgement.

Arguments and environment are byte strings without NUL; no shell expansion or
UTF-8 policy. An explicit environment replaces inheritance. PATH search is an
explicit option and uses the child's environment, unlike std.process.spawn's
parent-PATH behavior. Missing PATH uses `/usr/bin:/bin`; empty components mean
the child's cwd. A slash in argv[0] bypasses search. Relative paths resolve in the
child's cwd. Executables without a recognized format fail; there is no shell fallback.

Stdin/stdout/stderr support ignore, inherit, borrowed file and pipe. Parent pipe
ends are nonblocking; child pipe ends are blocking. Borrowed files retain their
existing blocking mode. No extra descriptor inheritance in v0.1. Child setup
marks descriptors above stderr CLOEXEC, resets signals, and clears the signal
mask. Linux pidfds and close_range(CLOEXEC) are required; unsupported kernels
fail explicitly. The I/O implementation is std.Io.Threaded only in v0.1.

## Capture and cancellation

Independent stdout/stderr limits count raw bytes, including binary output.
Exactly the limit is valid; one extra byte produces `output_limit`, retaining
only the allowed prefix. Storage is allocated before launch; output flooding
cannot grow it. Per-tick reads are bounded so one stream cannot starve its peer
or cancellation checks. EOF and child exit are separate conditions.

Capture defaults to terminating the owned group when its leader exits. The
optional `exit_policy = .drain_output` retains the unreaped leader and drains
descendant output until both streams close, bounded by the original deadline,
cancellation and output limits. This supports command consumers which require
EOF before completion without changing other callers' cleanup policy.

Results distinguish completed termination, timeout, cancellation and output
limit. Nonzero exit and signals are ordinary termination results. Setup/launch,
allocation and unexpected I/O failures are errors and still clean all owned
resources. Cancellation before successful launch is an error; cancellation
after launch returns bounded partial captures. Caller owns Result buffers and
must call deinit with the original allocator.

Neither run nor Child installs handlers or changes the parent's cwd/environment.
Hosts translate signals, UI Stop, or interpreter budgets into the cancellation
flag; std.Io cancellation is also honored. Signal/timeout cleanup precedes return.

## Owned failure reports (v0.2)

Add `runReport` alongside `run`. A Report owns bounded stdout/stderr on ordinary
completion, interruption, launch failure, and post-launch supervision failure.
Its outcome is completed, timed_out, canceled, output_limit, or failed with a
Failure containing the original error and phase (launch, stdout, stderr, poll,
or finish). Validation and allocation failures remain returned errors; OOM does
not promise an allocated report. Pre-launch cancellation/timeout are launch-phase
failures, preserving the distinction from an interrupted running child.

Report.term is optional: it contains observed or cleanup termination when known,
and is null when no termination is available. An interrupted command's cleanup
signal must not be presented as successful completion. Report.success requires
completed, exit zero, and no cleanup failure. Report.deinit releases both output
buffers exactly once with the original allocator.

An operation failure remains primary when forced cleanup also fails. Preserve
that secondary error in Report.cleanup_failure. Attempt the normal exact-child
stop, then always run final Child.deinit before returning a report or allocating
its output copies. The final owner closes all descriptors and attempts force
cleanup; missing status remains explicit rather than fabricated. No library
operation reaps an unrelated child or adds process-wide policy.

The two APIs share one capture/ownership implementation. run converts failures
back to returned errors before allocating result copies, preserving its existing
error behavior. runReport returns the owned report. Private syscall-operation
substitution in unit tests injects deterministic read, observation, finish, and
cleanup failures after fixture output; there are no public fault-injection knobs.

## Bounded child observation (v0.3)

The backend's remaining import owner combines a timed status check with reaping
and later group cleanup. `Child.pollFor(timeout_ms)` provides a timed status
check while keeping the exited leader unreaped. `pollUntil(deadline, token)`
shares an absolute `.awake` deadline with launch or application operations.
Both return null when time elapses and otherwise return the observed Term.
They allocate nothing, preserve pipes/PID/pidfd, and never signal descendants.
Repeated observation returns the same exit status until explicit cleanup.

Cancellation is checked before observation on every iteration, including an
immediate/expired deadline. Status is then checked before expiration, so an
already-observable exit is returned even with a zero or expired budget.
Token and std.Io cancellation return Canceled with ownership intact. Tokens
are per-operation borrows; no pointer is retained by Child after spawn or wait.
Polling retains the existing one-millisecond sleep between status checks.

`waitUntil(deadline, token)` composes observation with finish. A null observation
becomes Timeout; successful observation finishes the group/exact child.
Existing `wait(timeout_ms)` delegates to it with no explicit token, retaining
its existing behavior. These methods do not drain output or perform readiness
checks; consumers retain those responsibilities.

The compiled lifecycle example demonstrates borrowed logs, a shared launch/exit
budget, non-consuming status and explicit finish. Native tests cover timeout
and cancellation recovery, retained handles, signal status, independent children,
and a subreaper fixture proving a descendant remains live until explicit finish.
Only the fixture installs subreaper policy. Backend migration remains separate.

## Consumer integration boundaries

| Consumer | Shared mechanisms | Remains local |
| --- | --- | --- |
| Zeta | launch, capture, deadline, exact child cleanup | execution budgets, typed language errors, batch/report policy |
| zg-backend | commands, environments, process groups, wait/stop | containers, database ownership, browser profiles, evidence checks |
| Paneva | pidfd, nonblocking pipes/polling, redirection, shutdown | readiness protocol, VT/logind, UI state, app restart and subreaper policy |

Start future migrations at one caller per project and retain their existing
tests. No claim of consumer compatibility or full parity follows from this
package's isolated tests. The separate supervisor must be designed/tested before
replacing Paneva's adopted-descendant cleanup.

## Source basis

Read-only inspection, October 19, 2026:

- Zeta `334eb9c2fcb54c43dd4f5ce9bfc8089d64dca216`: process.zig,
  process_launch_linux.zig and tools/integration_support.zig.
- zg-backend `2a6c0edb68961dd8b9a2e8f8da6fc48236d5680d`:
  import_browser_runtime.zig and import_browser_process_test.zig.
- Paneva `dae00742cbb5d1fe8e0f418c4a2379a7c65b030d`: tools/worker.zig,
  tools/app-supervisor.zig, tools/run-apps.zig, services/controls.zig.
  Existing dirty launcher shell files were not used or modified.
- Installed Zig 0.17.0 standard library: process.zig, process/Child.zig,
  process/Environ.zig, Io/Threaded.zig and os/linux.zig.

October 20 v0.3 integration inspection: zg-backend `417baee3f34b43dc9e08c9e8479deba7c71851be`
with concurrent uncommitted work; import_browser_runtime.zig, import_browser_process.zig,
acceptance_runner.zig, native_server_manager.zig and native_startup_regressions.zig.
Commands already use runReport and several owners use Child; the older import
owner still uses std.process.Child. No backend files are modified by this release.
