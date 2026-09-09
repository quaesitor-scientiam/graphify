# Phase R reminder hook.
# Consumed by BOTH Claude Code and Cursor, which use different output schemas:
#   Claude Code : { hookSpecificOutput: { hookEventName, additionalContext } }
#   Cursor      : flat { permission, agent_message, additional_context }
# Cursor also rejects EMPTY stdout as invalid JSON and blocks the edit, so this
# script must always print exactly one JSON object and always allow the action.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Write-HookResult {
    param([string]$Message)

    $out = [ordered]@{
        # Cursor
        permission = 'allow'
        # Claude Code
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'allow'
        }
    }
    if ($Message) {
        $out.agent_message = $Message
        $out.additional_context = $Message
        $out.hookSpecificOutput.additionalContext = $Message
    }
    Write-Output ([pscustomobject]$out | ConvertTo-Json -Compress -Depth 6)
}

# Never block on a non-redirected stdin (would hang the hook until it times out).
$raw = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }

$file = $null
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    try {
        $data = $raw | ConvertFrom-Json
        # Claude Code: tool_input.file_path;  Cursor: file_path / path
        foreach ($c in @($data.tool_input.file_path, $data.file_path, $data.path)) {
            if (-not $file -and $c) { $file = [string]$c }
        }
    } catch {
        $file = $null
    }
}

if ($file -match 'h2_(mux_conn|conn|server|frame|hpack)\.v$') {
    Write-HookResult "PHASE R CHECK: If this edit responds to a Codex or external-reviewer finding - STOP and complete Phase R first: (1) record miss, (2) diagnose angle, (3) fix/add detector, (4) reproduce detector on BUGGY commit (must exit 1), (5) confirm detector clears on fixed tree, (6) log in code-review-misses corpus. Only THEN fix the code. Fixing first makes step 4 unverifiable."
} else {
    Write-HookResult
}
exit 0
