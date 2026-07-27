# graphify Claude Code hook.
# Handles SessionStart (inject standing guidance) and PreToolUse on Read/Grep/Glob
# (steer Claude to the graph when it can answer). Reads the hook JSON from stdin,
# emits hookSpecificOutput.additionalContext. Always non-blocking.
#
# The PreToolUse reminder only fires when the operation targets V source the graph
# actually indexes: for Read it checks the file against the graph's node set, so it
# stays silent on markdown/JSON/other-language files AND on branch-only or newly
# added .v files the (master) graph does not yet cover.

$ErrorActionPreference = 'SilentlyContinue'
$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { '{}'; exit 0 }

$evt = $data.hook_event_name
$proj = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { $data.cwd }
$projBase = if ($proj) { Split-Path $proj -Leaf } else { '' }

# A graph exists if it's in ./graphify-out, the central store ($GRAPHIFY_STORE or
# S:\graph_data) under the project name. Stays SILENT (user-scope safe) when none
# is found, so it never nags in projects that don't use graphify.
$candidates = @((Join-Path $proj 'graphify-out/graph.json'),
  (Join-Path (Join-Path 'S:\graph_data' $projBase) 'graph.json'))
if ($env:GRAPHIFY_STORE) { $candidates += (Join-Path (Join-Path $env:GRAPHIFY_STORE $projBase) 'graph.json') }
$graphPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

function Emit($eventName, $context) {
  @{
    hookSpecificOutput = @{
      hookEventName     = $eventName
      additionalContext = $context
    }
  } | ConvertTo-Json -Compress -Depth 6
}

# Get-GraphFileSet returns the set of repo-relative file paths that have nodes in
# the graph (case-insensitive). It is cached in a sidecar next to graph.json and
# rebuilt only when graph.json changes; the build streams the file line by line
# (low memory) and only inspects lines containing a "file" key. Returns $null if
# the set could not be determined, so callers can fall back to a heuristic.
function Get-GraphFileSet($graphPath) {
  try {
    $cache = "$graphPath.files"
    $cmp = [System.StringComparer]::OrdinalIgnoreCase
    $g = Get-Item $graphPath
    $fresh = (Test-Path $cache) -and ((Get-Item $cache).LastWriteTimeUtc -ge $g.LastWriteTimeUtc)
    $set = New-Object "System.Collections.Generic.HashSet[string]" $cmp
    if ($fresh) {
      foreach ($l in [System.IO.File]::ReadAllLines($cache)) { if ($l) { [void]$set.Add($l) } }
      return $set
    }
    $reader = [System.IO.File]::OpenText($graphPath)
    try {
      while ($null -ne ($line = $reader.ReadLine())) {
        if ($line.IndexOf('"file":') -ge 0) {
          $m = [regex]::Match($line, '"file":\s*"([^"]+)"')
          if ($m.Success) { [void]$set.Add($m.Groups[1].Value.Replace('\', '/')) }
        }
      }
    } finally { $reader.Close() }
    Set-Content -Path $cache -Value ($set -join "`n") -Encoding UTF8
    return $set
  } catch { return $null }
}

# To-Rel converts an absolute or relative path to a repo-relative, forward-slash
# path (matching how graph.json stores "file" values).
function To-Rel($p, $root) {
  if (-not $p) { return '' }
  $a = ($p -replace '\\', '/')
  $r = (($root -replace '\\', '/')).TrimEnd('/')
  if ($r -and $a.ToLower().StartsWith($r.ToLower() + '/')) { return $a.Substring($r.Length + 1) }
  return ($a -replace '^\./', '')
}

if (-not $graphPath) { '{}'; exit 0 }

switch ($evt) {
  'SessionStart' {
    Emit 'SessionStart' 'GRAPHIFY GRAPH AVAILABLE. Required workflow for tasks that involve navigating or understanding V code: (1) Start with overview or query_graph to orient — do NOT open files first. (2) Use get_node to inspect a symbol and its relationships with file:line. (3) Use get_body to read ONE declaration by name — do NOT read the whole file. (4) Only use Read/Grep/Bash for things the graph cannot answer (running tests, editing files, reading non-V source, or files not yet indexed). Every result includes file:line so you can always drill in precisely. EXCEPTION: for docs-only or file-creation tasks that do not require understanding V code, the graph is optional — a directory listing plus memory is a fine first move.'
  }
  'PreToolUse' {
    $ti = $data.tool_input
    $relevant = $false
    if ($null -ne $ti) {
      if ($ti.file_path) {
        # Read: emit only if the file actually has nodes in the graph. This skips
        # non-V files and branch-only / newly added .v files not yet indexed.
        $set = Get-GraphFileSet $graphPath
        if ($null -ne $set) {
          $relevant = $set.Contains((To-Rel ([string]$ti.file_path) $proj))
        } else {
          # Fall back to a .v extension check if the node set is unavailable.
          $relevant = ([string]$ti.file_path) -match '\.v$'
        }
      } else {
        # Grep/Glob: no single file to check; emit only when V is the explicit
        # target (a graph-answerable symbol search).
        $blob = @($ti.path, $ti.glob, $ti.pattern, $ti.type) -join ' '
        $relevant = ($ti.type -eq 'v') -or ($blob -match '\*\.v\b') -or ($blob -match '\.v$')
      }
    }
    if (-not $relevant) { '{}'; exit 0 }
    Emit 'PreToolUse' 'STOP: graphify graph available. Use query_graph/get_node/get_body instead of scanning files. get_body fetches one declaration by name; get_node shows all relationships with file:line. Only proceed with this file operation if the graph cannot answer the question.'
  }
  default { '{}' }
}
exit 0
