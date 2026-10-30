# Current delivery

## v0.6.0 Windows file-backed Child, October 30, 2026

HL2's interpreter removal needs native Windows command deadlines and reliable
descendant cleanup. Added an upstream Windows Child backend, preserving the
Linux capture/pipe implementation. Supported streams are ignore, inherit and
borrowed files; interactive pipes fail explicitly before launch. Job ownership
is established while the process is suspended. File duplicates share cursors,
and only explicitly selected standard handles are inherited.

Nine acceptance cases cover merged binary output/nonzero exit, timeout and
cancellation retaining ownership, leader observation and descendant cleanup,
cleanup without disturbing an independent owner, Unicode cwd/environment and
literal CRT arguments, failed-launch handle cleanup, and explicit parent/child
PATH lookup. A 70-descendant case exercises cleanup across query batches;
64 rapid natural exits exercise termination racing completion. CI adds native Windows Debug and ReleaseSafe runs. Cross builds
and Wine runs are supplemental, not native Windows qualification.

Linux Debug and ReleaseSafe `zig build test check --summary all`: 30/30 tests
and 11/11 steps in both profiles. Initial native run [41131100060](https://github.com/alogic0/zig-process/actions/runs/41131100060)
found a completion-barrier race and an unmapped executable-format error.
Windows can remove terminated members from job accounting before their process
handles become signaled. Cleanup now enumerates and joins verified job-member
handles before the job-wide containment safeguard. The original immediate
handle-signaling assertions are unchanged. Later native runs exposed lazy
handle initialization in the measurement control and ACCESS_DENIED while an
already-terminating process had not yet become signaled. The handle control now
warms the identical failure paths before measuring another 20 repetitions,
with no tolerance for growth. Cleanup waits for concurrent terminal transitions
on handles that already have PROCESS_TERMINATE rights.

[Native CI 41134813934](https://github.com/alogic0/zig-process/actions/runs/41134813934)
qualifies implementation `f5b60decb7c4cfc4668f410242ee0ce915e22ed1`:
Windows Debug and ReleaseSafe each pass all 9 cases; Linux Debug and ReleaseSafe
pass the existing 30 cases, examples and package consumer. Direct Wine execution
also passes 9/9 in both profiles. Local Linux `test check` executed 30/30 in
both profiles (the implementation commit body incorrectly described these local
runs as cached). Earlier native failures remain visible in CI history.
Consumer snapshot refresh and integration checks remain separate.

## v0.5.1 unlimited capture compatibility, October 20, 2026

HL2 binding generation sets a stdout limit but inherits Zig 0.17.0's unlimited
stderr default. Permit `std.math.maxInt(usize)` on either stream in `.grow`
mode so consumers can preserve that behavior. Preallocation still rejects
unlimited limits; finite defaults and limits are unchanged.

The capture loop uses saturating addition for its overflow-byte read allowance.
Storage grows with actual output, and the existing deadline, cancellation,
allocation-error and exact-child cleanup paths remain in effect. The existing
v0.5.0 parent-PATH option is also available for consumer migrations.

The regression case checks 20,000 bytes on both streams with either or both
unlimited, enforcement of a finite peer limit, and preallocation rejection
for either unlimited stream.

| Check | Result |
| --- | --- |
| `zig build test -Dtest-filter=unlimited --summary all`, both profiles | 1/1 test, 7/7 steps each |
| `zig build test check --summary all`, Debug and ReleaseSafe | 11/11 steps each; Debug reused passing tests, ReleaseSafe ran 30/30 |
| `zig build test --summary all` in tests/package, both profiles | 3/3 steps each |
| Format and diff checks | Passed |

These are library checks. HL2 snapshot refresh and consumer acceptance remain
with the adopting project.

## v0.5 interactive pipe adapters, October 20, 2026

Completed bounded prerequisite for backend import owner migration from
`53655012d44b8b14d32dd0eede48366f3226e50a`, library baseline
`b088421bf7406ddc269c5dec4ddf18c4345c6e24`: supply borrowed, cancelable
`Io.Reader`/`Io.Writer` adapters for nonblocking parent pipes. Standard Zig 0.17
file streams return WouldBlock instead of awaiting readiness. Preserve partial
I/O, EOF, errors and explicit Child ownership; leave framing and deadlines in
the consumer. No capture configuration or process-wide policy changes.

Finite cases: delayed binary input, writes larger than pipe capacity, EOF,
broken pipe, cancellation and reuse after cancellation. Reuse native fixtures,
run Debug/ReleaseSafe library and package checks, then commit this prerequisite.

Implemented as v0.5.0 with `PipeReader`/`PipeWriter` and explicit
`search_path_environment = .parent` compatibility for std child migrations.
Default child-environment lookup and runReport capture remain unchanged. A
parent-PATH test also proves that the child's explicit PATH is not overwritten.

| Check | Result |
| --- | --- |
| `zig build test check --summary all`, Debug and ReleaseSafe | 29/29 tests, 11/11 steps each |
| `zig build test --summary all` in tests/package, both profiles | 3/3 steps each, including interactive binary round trip and EOF |
| Format and diff checks | Passed |

The 29 tests comprise 25 public and four private cases. Added cases exchange
200,003 binary bytes through small buffers, cancel empty reads/full-pipe flushes,
resume the same reader/writer, retain unwritten buffered bytes, and check EOF and
BrokenPipe without closing or finishing the owner. Native fixture and package
examples use independent blocking peers. Backend integration and its finite
protocol/resource checks are recorded by that consumer.

## v0.4 capture allocation for host tools, October 20, 2026

Execution brief: remove full-limit capture reservation from ordinary commands.
HL2 host tooling at `2e4824a73cb39201d04006a83a38830709e7d677` permits
512 MiB stdout and 8 MiB stderr even for small version/Git commands. Library
baseline `f0f3073` reserves those limits before launch. Grow bounded buffers with
actual output by default; retain explicit preallocation for callers that need
capture storage reserved before spawning.

Outcome: shader/build diagnostics and archive inspection can keep generous hard
limits without reserving hundreds of MiB for every command. Existing backend
import/recovery command results and partial-error diagnostics remain compatible.
This changes library capture allocation, not consumer policy or source code.

Finite cases: high limits with small/empty output under a small allocator budget;
growth across chunks; binary and exact/overflow/zero limits in both modes;
allocation failure during live capture and result publication; exact-child and
descriptor cleanup; existing cancellation/deadline/drain/failure reports; package
use and host-tool compatibility. Reuse native fixtures and allocation-failure
checks, add only memory/growth controls. No Python tools, consumer migrations,
graphics runs, streaming callback API or descendant supervisor in this slice.

Exit: focused and full Debug/ReleaseSafe library checks, examples and package
consumer; isolated consumer checks; format/diff/staged review and a committed
valid slice.

Implemented as v0.4.0: `.capture_allocation = .grow` is the default; explicit
`.preallocate` reserves the two limits before spawn. Buffers grow only for bytes
actually read and retained, never beyond their stream limit. OOM during growth
remains a returned error after child/descriptor/buffer cleanup. Result buffers
remain independent allocations; the limits do not describe total peak RSS.

| Check | Result |
| --- | --- |
| `zig build test check --summary all`, Debug | 27/27 tests, 11/11 steps |
| `zig build test check run-capture run-poll run-lifecycle --summary all`, both profiles | 17/17 steps; Debug reused the passing tests, ReleaseSafe ran 27/27; three examples ran in each |
| `zig build test --summary all` in tests/package, both profiles | Both capture allocation modes and existing public APIs pass, 3/3 steps each |
| Backend `zig test --test-filter 'shared command'` with the library module, both profiles | 3/3 existing tests each: environment/results/allocation balance, actual 64 MiB/16 MiB boundaries, late output and cancellation |
| Temporary HL2 capture comparison, both profiles | Original Context.run and runReport match all bytes for Zig version (7), Git revision (41), and glslc package tar output (204800) |
| Zig format and whitespace checks | Passed |

The 27 tests comprise 23 public cases and four private capture cases. New checks
prove that 512 MiB/8 MiB caps with empty or small output fit a 128 KiB allocator;
both modes preserve exact/zero/binary/overflow boundaries; and forced allocation
failure after a live child's stdout or stderr passes 8 KiB leaves unchanged
descriptor/child inventories. Existing exhaustive allocation-failure tests also
cover launch and publication of successful and failed captures.

The HL2 probe copied the original common/resource-report modules into a temporary
directory and compared them against the shared library. Its package command was
`dpkg-deb --fsys-tarfile .tools/vulkan/packages/glslc_2023.8-1build1_amd64.deb`;
the 204800 output bytes have SHA-256
`3ac8c7c428a5b281fd5a7725b03d4caa762281d3a5b233971d7d747c83855b3f`.
Temporary sources/outputs were removed. Backend checks used the concurrent
working tree at `1c5e553f50f7a945882df10caa02e3d6228800fc`, without building or
starting its services. Neither consumer's sources were changed. Full HL2
workflow/shader qualification and consumer migrations remain separate.

## v0.3 bounded child observation, October 20, 2026

Execution brief: add timed, non-reaping observation and deadline/token-aware
waiting for backend process owners. This protects import/recovery verification
from premature group cleanup and lost ownership after timeout or cancellation.
The inspected backend baseline is `417baee3f34b43dc9e08c9e8479deba7c71851be`
with concurrent uncommitted work; library baseline is
`b7a68f3f3605386374478389ad5f0694a768919d`.

Scope: `Child.pollFor`, `pollUntil` and `waitUntil`, existing `wait` delegation,
a compiled log-backed lifecycle example and backend migration guidance. Keep
browser profiles, JSON/error mappings, readiness, resource ownership and signal
policy in consumers. Backend migration and descendant supervision are excluded.

Finite cases: zero/expired deadlines; live timeout retaining handles; observed
exit retaining PID/group/pipes; explicit token and std.Io cancellation; repeated
observation and wait; signal status; group cleanup only on finish/stop; independent
children; closed owners; log redirection and package import. Reuse native fixtures
and existing lifecycle/capture regressions. Exit after Debug/ReleaseSafe tests,
examples and package checks, format/diff review and a committed valid slice.

Implemented as v0.3.0. Observation returns null on timeout and preserves the
leader, group and handles even after exit; waitUntil explicitly finishes on
success. Existing wait keeps its previous behavior through the shared loop.
Cancellation tokens are per-call borrows. README contains the concrete backend
mapping and explains the deliberate change from reaping during status checks
to retaining ownership until explicit cleanup.

| Check | Result |
| --- | --- |
| `zig build test check run-capture run-poll run-lifecycle --summary all` | 24/24 tests, three examples, 17/17 steps |
| Same command with `-Doptimize=ReleaseSafe` | 24/24 tests, three examples, 17/17 steps |
| `zig build test --summary all` in tests/package, Debug and ReleaseSafe | Capture/report and new lifecycle APIs pass, 3/3 steps each |
| Backend `zig build build-dev-cli build-import-browser-process`, Debug and ReleaseSafe | Both build, including native-schema-fixture; 8/8 steps each |
| Zig format and whitespace checks | Passed |

The 24 tests comprise 21 public acceptance cases and three private capture-unit
cases. Four added cases cover the lifecycle matrix above. The existing isolated
subreaper fixture now independently checks that the descendant remains alive
after observation, then verifies KILL and exact reaping after finish.
The lifecycle example verifies actual log bytes and removes its temporary log.
Backend compatibility checks compiled its concurrent working tree at the stated
HEAD into temporary installation prefixes and removed those outputs; no backend
services or workflow suites ran. Backend sources were not modified by this slice.
Full import owner/protocol migration and seller workflow acceptance remain separate.

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
