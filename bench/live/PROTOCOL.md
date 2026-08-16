# Live end-to-end token measurement

`cmd/bench` measures artifact sizes. This measures the real thing: **does the
same Claude Code task consume fewer tokens with graphify wired vs. not?** It
needs you to drive two actual sessions; the scripting just tallies the result.

> **Turnkey version ready at `S:\graphify-bench\`** — two identical copies of a
> real V module (one plain, one pre-wired with graphify + a prebuilt graph), a
> fixed `TASK.md`, and `RUN.md` with exact steps. Use that for a quick run; the
> general protocol below explains the method.

## Setup

1. Pick a **target repo** — ideally a real, mid/large V codebase, *not* graphify
   itself (too small, self-serving). E.g. a clone of `vlib/v/ast`.
2. Pick **one fixed task prompt** that requires understanding structure, not a
   trivial lookup. Use the *same* prompt verbatim in both conditions. Examples:
   - "Explain how parsing produces a function declaration: which types and
     functions are involved and how they connect. Don't modify code."
   - "Where is X defined, what calls it, and what does it depend on?"
   - "Give me a map of this module's main types and the relationships between them."

## Run the two conditions

**Condition A — baseline (no graphify):**
1. Ensure the target repo has **no** graphify wiring: no `.mcp.json`, no
   `.claude/skills/graphify`, no graphify hooks in `.claude/settings.json`.
2. Start a **fresh** Claude Code session in the repo (`/clear` or new session).
3. Paste the task prompt. Let it finish. Do nothing else in that session.
4. Note the transcript (see "Finding transcripts").

**Condition B — graphify wired:**
1. Copy graphify's `.claude/` and `.mcp.json.example` (as `.mcp.json`) into
   the target repo — no path edits needed, both use `${CLAUDE_PROJECT_DIR}`.
2. Build the graph once: `bin/graphify extract .` (`bin/graphify.exe` on Windows)
3. Approve the `graphify` MCP server and reload so its tools are available.
4. Start a **fresh** session, paste the **same** prompt, let it finish.

## Measure

```
pwsh -NoProfile -File bench\live\count_tokens.ps1 baseline=<A>.jsonl graphify=<B>.jsonl
```

Compare on **unique input** (`input_tokens + cache_creation_input_tokens`) — the
new context pulled in per session. Ignore `cache-read` for the headline: it
re-counts cached context every turn, so it grows with turn count rather than
with how much source was ingested.

## Finding transcripts

Sessions live at `~/.claude/projects/<encoded-repo-path>/<session-id>.jsonl`
(path separators become `-`). Grab the newest right after a run:

```
Get-ChildItem "$env:USERPROFILE\.claude\projects" -Recurse -Filter *.jsonl |
  Sort-Object LastWriteTime -Descending | Select-Object -First 2 FullName, LastWriteTime
```

## Controls (so the number means something)

- **Same** prompt, model, and repo; fresh session for each; exactly one task per
  session (no follow-ups — they pollute the tally).
- Baseline must genuinely lack graphify; condition B must have the graph built
  and the MCP tools actually available.
- The model must be *allowed* to use the graph tools (don't deny them).
- Run each condition **3×** and average — model behavior varies run to run.
- Report `unique input` for A vs B and the ratio. Expect something **below** the
  `cmd/bench` Task A figure (~10–20×): the live model still reads some bodies,
  emits reasoning, and doesn't navigate perfectly. A real, repeatable 2–5× here
  would already be a strong result.
