# Current delivery

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

Design recorded; implementation and verification pending. A dedicated descendant
supervisor, non-Linux targets and actual consumer adoption are outside v0.1.
