# Deadline-aware readiness waits

Status: implemented and validated, 2026-11-05.

## Problem and scope

Linux child observation currently sleeps for one millisecond between status
checks. A consumer measuring short commands used an indefinite pidfd poll to
avoid this delay, losing its configured timeout and token cancellation wakeup.
Move readiness waiting into the provider while retaining the existing public
`pollFor`, `pollUntil`, `wait`, and `waitUntil` contracts.

## Implementation

1. Wait for pidfd readability under the caller's absolute awake deadline.
   Use bounded kernel waits (at most 10 ms) to check both the atomic token and
   std.Io cancellation even if neither produces a syscall wakeup. Child exit
   wakes the wait immediately; the interval bounds cancellation observation,
   not exit observation. Retry interruptions against the original deadline.
2. Keep cancellation before status, and status before deadline expiry. Preserve
   non-consuming observation, exact-child reaping, borrowed handles, and owned
   group cleanup. Reuse readiness waiting for the exec handshake and stop grace
   period where the same ownership rules apply. Leave capture and Windows
   implementations unchanged.
3. Add native regressions for token changes during a wait, std.Io cancellation,
   timeout recovery, and prompt exit observation without adopting timing-based
   performance gates. Retain all existing ownership and independent-child tests.
4. Update version, design and delivery notes. Publish a committed source revision
   for source-only adoption in zig-test-support and z_llvm; create no archives.

## Validation and completion

Run `zig fmt`, native `zig build test check` in Debug and ReleaseSafe, and
`git diff --check`. Inspect the final diff and commit the completed library slice.
Record actual results here. Consumer acceptance is separate from provider tests;
do not claim Windows qualification or benchmark speedups from these checks.

## Results

- Implemented in version 0.6.1 without changing public signatures.
- Linux observation, launch acknowledgement and stop grace use bounded ppoll;
  capture and Windows code are unchanged.
- Debug and ReleaseSafe `zig build test check --summary all`: 11/11 build steps,
  31 provider cases (27 lifecycle plus 4 capture-failure). Four unchanged report
  tests were cached on the final Debug rerun; all executed in ReleaseSafe.
- Formatting and `git diff --check` pass. The new regression verifies cancellation
  after waiting begins, timeout recovery and exact-owner cleanup. Its initial
  EOF-only fixture release was corrected to send the input that fixture requires.
- Consumer adoption and any future benchmark measurements remain separate.
