# Live A/B: same task, same corpus, graphify available vs not.
#
# Corpus: vlib/v (2,885 .v files, 161 modules) copied byte-identically into both
# arms, with .claude/AGENTS.md excluded so neither arm inherits the vlang repo's
# own agent config -- it mentions graphify (which would coach the baseline) and
# its 725-line AGENTS.md would load into both, compressing the ratio toward 1.0.
#
# BOTH arms run --safe-mode. That is the whole point: the user's global
# settings.json registers a SessionStart hook that injects graphify guidance
# into *every* session, so without it the "unwired" baseline is being told to
# use the thing it is supposed to be a control for. --strict-mcp-config does not
# stop hooks; only --safe-mode does. It also disables plugins, so neither arm
# silently runs under a plugin agent.
#
# --safe-mode also ignores --mcp-config, so the wired arm gets graphify through
# the CLI plus an appended system prompt rather than MCP. That keeps isolation
# identical on both sides, leaving exactly one difference: whether the graph is
# available. (In headless runs MCP tools also load deferred, costing extra
# ToolSearch calls, so the CLI path is if anything the fairer comparison.)

param([int]$Rounds = 3, [string[]]$Tasks = @('nav', 'deep'), [string]$Out = '')

# Passed through `pwsh -File`, `-Tasks deep,summarize` arrives as ONE string
# rather than an array, so `-contains` silently matches nothing and the run
# does nothing at all. Normalise both forms.
$Tasks = @($Tasks | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$ErrorActionPreference = 'SilentlyContinue'
$base = Join-Path $env:USERPROFILE '.claude\projects'
# Each run writes its own file. A fixed name meant every run deleted the last one's
# rows, so the earlier rounds could not be combined or re-checked. Validity flags
# go to a sidecar file, so the results file keeps the four-field format analyze2.py reads.
$res   = if ($Out) { $Out } else { 'S:\gf-bench2\results_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt' }
$flags = "$res.flags"
# Forward slashes on purpose: the agent invokes these through the Bash tool,
# which is MSYS2 bash. It strips backslashes, so 'S:\vProjects\...' arrived as
# 'S:vProjectsgraphifybingraphify.exe' and the wired arm's first three calls
# died with "command not found" before it worked around them on its own -- a
# harness bug that inflated the wired arm's cost, not a graphify one.
$gexe = 'S:/vProjects/graphify/bin/graphify.exe'
$gjson = 'S:/gf-bench2/wired/graphify-out/graph.json'

$wiredPrompt = @"
This codebase has a prebuilt graphify code graph. For structural questions
(where something is defined, what calls or references it, how two things
connect, what a module contains), query the graph instead of grepping or
reading whole files. Every result carries file:line, so drill in with a
targeted read rather than loading a file to find one thing.

Run these with Bash (each also takes --graph "$gjson"):
  $gexe overview --graph "$gjson"
  $gexe query "<text>" --budget 2000 --graph "$gjson"
  $gexe explain <symbol> --graph "$gjson"
  $gexe body <symbol> --graph "$gjson"
  $gexe path <A> <B> --graph "$gjson"

Workflow: if you already have an exact symbol name, call explain on it
directly -- it returns the doc comment, signature, and relationships (calls,
callers, definers) in one shot. Reach for query only when you don't have an
exact name yet and need to discover candidates by keyword. Read the body only
when explain's doc/signature genuinely isn't enough to answer the question.

Symbol ids are module-qualified, e.g. "wired.v.ast.Scope.contains", not just
"Scope.contains" or "contains" -- if explain reports no match on a guessed id,
that means the id is wrong, not that the symbol is absent; get the exact id
from a query result first. To see a declaration's real source, call `body`
directly on its exact id rather than grepping/reading the file by hand.
"@

$navTask = @'
Without editing any files, help me understand this codebase:
1. Give a high-level map: the main modules here and what each is responsible for.
2. For the method type_to_str: what does it call, and what calls it? Include callers in other modules, not just its own.
3. For register_sym: list what calls it, across modules.
Keep it concise. Do not modify anything.
'@

$deepTask = @'
Without editing any files, explain step by step what these two functions DO internally — walk through their actual logic, not just the signature:
1. new_table — what does it set up and return?
2. type_to_str — how does it turn a type into a string?
Be concrete about the implementation and cite the specific lines involved. Do not modify anything.
'@

# Purpose-and-rationale rather than implementation. The `deep` task asks for a
# line-by-line walkthrough, which a doc comment cannot answer -- and two of its
# three targets are undocumented anyway -- so it cannot measure whether doc
# capture helped. These three symbols have substantive multi-line docs and live
# in different modules, so the baseline has to find them before it can read them.
$sumTask = @'
Without editing any files, briefly explain what each of these is FOR and why it exists — one short paragraph each:
1. launch_tool
2. CacheManager
3. find_var_decl
I want purpose and rationale, not a line-by-line walkthrough of the implementation. Do not modify anything.
'@

# Targets the specific unresolved-call gap under test: `contains` is declared
# on many unrelated types across this corpus (ast.Attr, ast.Scope, ast.Table's
# type_contains_placeholder-style helpers, several generics/interface test
# types, etc.), and graphify's own extraction leaves the call in
# Gen.local_closure_cleanup_scope_at unresolved -- confirmed directly against
# the live wired graph.json: the `contains` calls edge still carries the raw
# name, not a resolved symbol id, while the sibling `innermost` call on the
# same line resolves cleanly. Unlike the first draft of this task (os.Process,
# living in vlib/os -- outside this vlib/v-only corpus, which forced both arms
# to fetch external source and invalidated the comparison), ast.Scope.contains
# is fully declared in-corpus at vlib/v/ast/scope.v, so this isolates exactly
# the variable under test: does resolving an in-corpus name-ambiguous call
# change token spend, with no external-lookup confound either way.
$resolveTask = @'
Without editing any files, look at Gen.local_closure_cleanup_scope_at in vlib/v/gen/c/cgen.v. It calls fn_scope.contains(pos), then on success calls fn_scope.innermost(pos).
1. This codebase declares a method named `contains` on several different types. Identify exactly which type's `contains` this call resolves to — name the actual declaring type, not a vague description.
2. Show me the real implementation of both contains and innermost.
3. Explain why innermost calls contains internally too, and what would go wrong if the outer contains check in local_closure_cleanup_scope_at were skipped.
Do not modify anything.
'@

function NewestT($proj) {
  (Get-ChildItem (Join-Path $base $proj) -Filter *.jsonl |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

# --- preflight: fail fast instead of burning a dozen no-op runs -------------
# The previous attempt ran all 12 sessions against an expired OAuth token and
# produced 12 synthetic "Failed to authenticate" transcripts before anyone
# noticed. Check once, up front.
Set-Location 'S:\gf-bench2\baseline'
claude --safe-mode -p "reply with the single word: ok" --model sonnet 2>&1 | Out-Null
$probe = NewestT 'S--gf-bench2-baseline'
if ((Select-String -Path $probe -Pattern 'Failed to authenticate','OAuth session expired' -Quiet)) {
  Write-Host "PREFLIGHT FAILED: not authenticated. Run 'claude' interactively and log in, then re-run." -ForegroundColor Red
  exit 1
}
Write-Host "preflight ok - authenticated | tasks: $($Tasks -join ', ') | rounds: $Rounds"
if (-not $Tasks) { Write-Host 'no tasks selected - nothing to do' -ForegroundColor Red; exit 1 }

if (Test-Path $res) { Write-Host "$res already exists - pass -Out with a new name" -ForegroundColor Red; exit 1 }

foreach ($r in 1..$Rounds) {
  $all = @(@{ k = 'nav'; task = $navTask }, @{ k = 'deep'; task = $deepTask }, @{ k = 'summarize'; task = $sumTask }, @{ k = 'resolve'; task = $resolveTask })
  foreach ($t in ($all | Where-Object { $Tasks -contains $_.k })) {
    Write-Host "round $r / $($t.k) : baseline..."
    Set-Location 'S:\gf-bench2\baseline'
    claude --safe-mode -p $t.task --dangerously-skip-permissions --model sonnet 2>&1 | Out-Null
    $b = NewestT 'S--gf-bench2-baseline'

    Write-Host "round $r / $($t.k) : wired..."
    Set-Location 'S:\gf-bench2\wired'
    claude --safe-mode -p $t.task --append-system-prompt $wiredPrompt --dangerously-skip-permissions --model sonnet 2>&1 | Out-Null
    $w = NewestT 'S--gf-bench2-wired'

    # A contaminated arm must fail loudly, not quietly produce a number.
    function Flag($msg, $color) {
      Write-Host "  !! $msg" -ForegroundColor $color
      Add-Content $flags "$($t.k)|$r|$msg"
    }
    if (Select-String -Path $b -Pattern 'graphify' -Quiet) {
      Flag 'baseline referenced graphify - arm is contaminated, results invalid' 'Red'
    }
    if (-not (Select-String -Path $w -Pattern 'graphify' -Quiet)) {
      Flag 'wired never used graphify - measuring nothing' 'Yellow'
    }
    # "graphify appears in the transcript" is too weak: it also matches a failed
    # invocation, since the command string itself contains the word. Check the
    # calls actually ran.
    if (Select-String -Path $w -Pattern 'command not found','Exit code 127' -Quiet) {
      Flag 'wired had failed graphify invocations - cost is inflated, results suspect' 'Red'
    }

    "$($t.k)|$r|$b|$w" | Add-Content $res
  }
}
'DONE' | Add-Content $res
Write-Host "done -> $res"
