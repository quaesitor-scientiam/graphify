---
description: Build or refresh the graphify code graph for this project, then summarize it
argument-hint: "[path]  (defaults to .)"
allowed-tools: Bash, Read
---

Refresh this project's code graph and report what's in it.

1. Run the extractor with the Bash tool from the project root. Use the path
   `$ARGUMENTS` if it is non-empty, otherwise default to `.`:

   `bin/graphify extract .`   (`bin/graphify.exe` on Windows; replace `.` with `$ARGUMENTS` when given)

2. Read `graphify-out/GRAPH_REPORT.md` and give the user a short summary:
   symbol/edge counts, the most-connected symbols, and 2–3 suggested
   `graphify query`/`explain` invocations they could run next.

Do not read source files for this — everything you need is in the report.
