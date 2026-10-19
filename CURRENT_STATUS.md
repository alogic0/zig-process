# Current delivery

## v0.2 owned failure reports, October 19, 2026

`runReport` adds owned partial stdout/stderr for launch and supervision failures,
with the original error and phase, optional observed/cleanup termination, and a
separate secondary cleanup error. Validation/OOM remain returned errors. Existing
`run` uses the same capture core and preserves its returned-error API.

Acceptance covers binary output before deterministic stdout/stderr/poll/finish
failures, primary/secondary error preservation, exact-child reaping, descriptor
closure, allocation failures while copying partial and successful output, normal
completion, timeout/limits, launch failure/cancellation, and package import.

| Check | Result |
| --- | --- |
| `zig build test check run-capture run-poll --summary all` | 20/20 tests, both examples ran, 14/14 build steps |
| Same command with `-Doptimize=ReleaseSafe` | 20/20 tests, both examples ran, 14/14 build steps |
| `zig build test --summary all` in tests/package, Debug and ReleaseSafe | Both APIs imported/executed, 3/3 steps in each mode |
| `zig fmt --check build.zig build.zig.zon src tests examples` | Passed |
| `git diff --check` and staged review | Passed |

The 20 tests comprise 17 public acceptance cases and three private capture-unit
cases. Fault substitution occurs only after both fixture streams are captured;
the finish case retains the natural exit code. A failed stop preserves its
secondary error while final teardown kills/reaps the fixture. Failure injection
also covers every allocator failure while publishing partial output. PID probes,
exact-child waits, stable descriptor counts, and the testing allocator verify
ownership. Consumer adoption remains a separate change.

## v0.1 output draining

October 19 consumer prerequisite: optional `run.exit_policy = .drain_output`
preserves output written after the leader exits, with the leader retained until
EOF or bounded timeout/cancellation/overflow cleanup. The existing default still
terminates the group on leader exit. This supports the authorized zg-backend
command integration without adding backend policy to the package.

`zig build test check --summary all` and the same command with
`-Doptimize=ReleaseSafe` pass 14/14 tests and 8/8 build steps. The new isolated
subreaper fixture requires a descendant to observe the leader's zombie state
before writing both streams, and checks a held-open-pipe timeout preserves the
leader's exit code and kills/reaps the descendant. Consumer acceptance belongs
to zg-backend's own checks. The original standalone completion below retains
its original 13-test scope.

Standalone library requested October 19, 2026. Scope: owned Linux process API,
bounded command runner, documentation and reusable native fixtures. No consumer migration.

Finite acceptance cases:

1. Direct argv, byte preservation, cwd by path/handle, explicit environment and PATH.
2. Nonzero exit, signal termination, failed exec and invalid options.
3. Independent simultaneous output limits, exact/zero limits and binary bytes.
4. Deadlines with open and closed output pipes; explicit and std.Io cancellation.
5. Nonblocking observation, timeout preserving ownership, graceful/forced stop.
6. Group cleanup after leader exit, with unrelated child ownership preserved.
7. Inherited/redirected streams, stdin pipe, descriptor isolation and closure.
8. Repeated failure/success lifecycle and allocation-failure cleanup.
9. Package import, buildable examples, Debug and ReleaseSafe verification.

## Completion, October 19, 2026

v0.1 is implemented. The 13 native tests cover all nine case groups above on
x86_64 Linux with the pinned Zig 0.17.0 compiler and std.Io.Threaded. Both Debug
and ReleaseSafe pass. This record belongs to the implementation commit containing
it; it is not a consumer acceptance receipt.

| Check | Result |
| --- | --- |
| `zig build test check run-capture run-poll --summary all` | 13/13 tests; both examples compiled and ran; 12/12 build steps |
| Same command with `-Doptimize=ReleaseSafe` | 13/13 tests; examples ran; 12/12 steps |
| `zig build test --summary all` from `tests/package` | Independent path dependency imported and executed; 3/3 steps |
| Same package command with `-Doptimize=ReleaseSafe` | 3/3 steps |
| `zig fmt --check build.zig build.zig.zon src tests examples` | Passed |
| Staged diff and whitespace review | Passed |

The lifecycle checks observe stable descriptor counts and unchanged owned-child
lists after allocation-failure injection and 24 failed launches. The group test
uses an isolated fixture subreaper, verifies the original exit code and KILL of
the descendant, and reaps it. Concurrent commands retain separate results. Atomic
and std.Io cancellation cover cleanup and a low-level wait retaining ownership.
Cancellation racing exec acknowledgement accepts either documented phase outcome,
with cleanup verified in both; it does not rely on a scheduling sleep.

During development, fixture executable paths were made absolute for changed-cwd
tests and allocation injection disabled in-place resizing to make failure indices
deterministic. Launch setup was corrected to snapshot inherited standard streams
before opening descriptors when stdin/stdout are closed. Those cases now pass.

The bounded delivery is complete. A dedicated descendant supervisor, non-Linux
targets, performance benchmarking and actual consumer adoption remain outside
v0.1. DESIGN.md records the future migration boundaries; no Zeta, Paneva, backend
or architecture files were changed by this delivery.
