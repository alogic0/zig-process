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

Results distinguish completed termination, timeout, cancellation and output
limit. Nonzero exit and signals are ordinary termination results. Setup/launch,
allocation and unexpected I/O failures are errors and still clean all owned
resources. Cancellation before successful launch is an error; cancellation
after launch returns bounded partial captures. Caller owns Result buffers and
must call deinit with the original allocator.

Neither run nor Child installs handlers or changes the parent's cwd/environment.
Hosts translate signals, UI Stop, or interpreter budgets into the cancellation
flag; std.Io cancellation is also honored. Signal/timeout cleanup precedes return.

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
