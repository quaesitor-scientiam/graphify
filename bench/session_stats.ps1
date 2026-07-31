param(
  [int]$Days = 14,
  [switch]$IncludeBench
)

$projectsDir = Join-Path $env:USERPROFILE '.claude\projects'
$cutoff = (Get-Date).AddDays(-$Days)

# Collect all main session jsonl files
$files = Get-ChildItem $projectsDir -Recurse -Filter '*.jsonl' -Depth 1 |
  Where-Object { $_.LastWriteTime -ge $cutoff }

if (-not $IncludeBench) {
  $files = $files | Where-Object { $_.FullName -notmatch 'graphify-bench' }
}

$rows = @()

foreach ($f in ($files | Sort-Object LastWriteTime)) {
  # Derive a short project label — use just the last path segment, truncated
  $proj = ($f.Directory.Name -replace '^S--', '' -replace '-', '/') -split '/' | Select-Object -Last 1
  if ($proj.Length -gt 20) { $proj = $proj.Substring(0, 19) + '…' }
  $date = $f.LastWriteTime.ToString('MM-dd HH:mm')

  $main = @{}
  $subs = @{}

  function Count-File($path, [ref]$tbl) {
    foreach ($line in (Get-Content $path -ErrorAction SilentlyContinue)) {
      try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
        if ($obj.type -ne 'assistant') { continue }
        @($obj.message.content) | Where-Object { $_.type -eq 'tool_use' } | ForEach-Object {
          $n = $_.name
          $tbl.Value[$n] = ($tbl.Value[$n] ?? 0) + 1
        }
      } catch {}
    }
  }

  Count-File $f.FullName ([ref]$main)

  $subdir = Join-Path $f.DirectoryName ($f.BaseName + '\subagents')
  if (Test-Path $subdir) {
    foreach ($sf in (Get-ChildItem $subdir -Filter '*.jsonl')) {
      Count-File $sf.FullName ([ref]$subs)
    }
  }

  $gMain = @($main.Keys | Where-Object { $_ -match '^mcp__graphify__' } | ForEach-Object { $main[$_] } | Measure-Object -Sum).Sum
  $gSub  = @($subs.Keys | Where-Object { $_ -match '^mcp__graphify__' } | ForEach-Object { $subs[$_] } | Measure-Object -Sum).Sum

  $rows += [PSCustomObject]@{
    Date     = $date
    Project  = $proj
    gMain    = $gMain
    gSub     = $gSub
    query    = ($main['mcp__graphify__query_graph'] ?? 0) + ($subs['mcp__graphify__query_graph'] ?? 0)
    node     = ($main['mcp__graphify__get_node']    ?? 0) + ($subs['mcp__graphify__get_node']    ?? 0)
    body     = ($main['mcp__graphify__get_body']    ?? 0) + ($subs['mcp__graphify__get_body']    ?? 0)
    overview = ($main['mcp__graphify__overview']    ?? 0) + ($subs['mcp__graphify__overview']    ?? 0)
    path     = ($main['mcp__graphify__shortest_path'] ?? 0) + ($subs['mcp__graphify__shortest_path'] ?? 0)
    Read     = ($main['Read'] ?? 0) + ($subs['Read'] ?? 0)
    Grep     = ($main['Grep'] ?? 0) + ($subs['Grep'] ?? 0)
    Glob     = ($main['Glob'] ?? 0) + ($subs['Glob'] ?? 0)
    Bash     = ($main['Bash'] ?? 0) + ($main['PowerShell'] ?? 0) + ($subs['Bash'] ?? 0) + ($subs['PowerShell'] ?? 0)
  }
}

if (-not $rows) {
  Write-Host "No sessions found in the last $Days days."
  exit 0
}

# Print table  (graphify shown as main/sub)
$fmt = '{0,-14} {1,-20} {2,8} {3,6} {4,5} {5,5} {6,9} {7,5} | {8,5} {9,5} {10,5} {11,5}'
$hdr = $fmt -f 'Date','Project','m/s','query','node','body','overview','path','Read','Grep','Glob','Bash'
Write-Host $hdr
Write-Host "  (graphify: m=main agent  s=subagents)"
Write-Host ('-' * ($hdr.Length + 2))

foreach ($r in $rows) {
  $ms = if (($r.gMain + $r.gSub) -gt 0) { "$($r.gMain)/$($r.gSub)" } else { '-' }
  $q  = if ($r.query    -gt 0) { $r.query    } else { '-' }
  $n  = if ($r.node     -gt 0) { $r.node     } else { '-' }
  $b  = if ($r.body     -gt 0) { $r.body     } else { '-' }
  $o  = if ($r.overview -gt 0) { $r.overview } else { '-' }
  $p  = if ($r.path     -gt 0) { $r.path     } else { '-' }
  Write-Host ($fmt -f $r.Date, $r.Project, $ms, $q, $n, $b, $o, $p, $r.Read, $r.Grep, $r.Glob, $r.Bash)
}

Write-Host ''
Write-Host 'graphify tools:'
Write-Host '  query    search the graph by keyword, returns matching symbols + neighbors (use instead of grep)'
Write-Host '  node     one symbol: signature, file:line, and all relationships (calls, callers, references)'
Write-Host '  body     source of one declaration by name (use instead of reading the whole file)'
Write-Host '  overview compact map of the codebase: counts + most-connected symbols'
Write-Host '  path     shortest relationship chain between two symbols'
Write-Host ''
Write-Host "Bash column includes PowerShell calls. Bench sessions excluded (use -IncludeBench to add them)."
