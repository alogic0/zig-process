# Working on zig-process

Use the compiler pinned in `.zigversion`. Keep this an independent Git repository.
Read DESIGN.md and CURRENT_STATUS.md before changing ownership or public APIs.
Keep product policy in consumers; this package has no Zeta, Paneva or backend dependency.
Never reap unrelated children or install process-wide signal/subreaper policy in the library.
Format Zig files, run focused checks in Debug and ReleaseSafe, and run `git diff --check`.
Review staged changes and commit each valid slice with a complete message in a temporary
file via `git commit -F`; remove the message file afterward with plain `rm`.
