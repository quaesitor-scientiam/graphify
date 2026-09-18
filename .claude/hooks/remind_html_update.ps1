# Reference-doc reminder hook (post-edit).
# Consumed by BOTH Claude Code and Cursor, which use different output schemas:
#   Claude Code : { hookSpecificOutput: { hookEventName, additionalContext } }
#   Cursor      : flat { additional_context }   (post-edit events take no `permission`)
# Cursor rejects EMPTY stdout as invalid JSON and blocks the edit, so this script
# must always print exactly one JSON object.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Write-HookResult {
    param([string]$Message)

    $out = [ordered]@{
        hookSpecificOutput = [ordered]@{ hookEventName = 'PostToolUse' }
    }
    if ($Message) {
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

if ($file -match 'SKILL\.md|detect_.*\.sh') {
    Write-HookResult "REMINDER: SKILL.md or detector changed - update C:\Users\john3\Documents\code-review-reference.html before continuing (Detectors tab + Miss Corpus table + subtitle date)."
} else {
    Write-HookResult
}
exit 0
