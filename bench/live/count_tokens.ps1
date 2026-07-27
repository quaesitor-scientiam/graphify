# Sum token usage from one or more Claude Code session transcripts (.jsonl) and
# compare them. Use to measure a real task run with graphify wired vs. not.
#
#   pwsh -NoProfile -File count_tokens.ps1 baseline=<path>.jsonl graphify=<path>.jsonl
#
# Pass "label=path" pairs, or bare paths (the file name is used as the label).
# Metrics per session:
#   unique input  = sum(input_tokens + cache_creation_input_tokens)  <-- new context
#                   pulled in. THIS is the apples-to-apples comparison metric.
#   total input   = unique input + cache_read_input_tokens (re-read cached context;
#                   grows with turn count, so it is NOT a clean per-task measure).
#   output        = sum(output_tokens)

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Sessions)

if (-not $Sessions -or $Sessions.Count -eq 0) {
  Write-Output 'usage: count_tokens.ps1 [label=]<transcript.jsonl> ...'
  exit 1
}

function Measure-Transcript($path) {
  $s = [ordered]@{ turns = 0; input = 0; cache_create = 0; cache_read = 0; output = 0 }
  foreach ($line in [System.IO.File]::ReadLines($path)) {
    if (-not $line.Trim()) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    $u = $o.message.usage
    if (-not $u) { $u = $o.usage }
    if (-not $u) { continue }
    $s.turns++
    $s.input        += [int]($u.input_tokens)
    $s.cache_create += [int]($u.cache_creation_input_tokens)
    $s.cache_read   += [int]($u.cache_read_input_tokens)
    $s.output       += [int]($u.output_tokens)
  }
  $s.unique_input = $s.input + $s.cache_create
  $s.total_input  = $s.unique_input + $s.cache_read
  return $s
}

$results = [ordered]@{}
foreach ($a in $Sessions) {
  if ($a -match '^([^=]+)=(.+)$') { $label = $Matches[1]; $p = $Matches[2] }
  else { $p = $a; $label = Split-Path $a -Leaf }
  if (-not (Test-Path $p)) { Write-Warning "missing: $p"; continue }
  $results[$label] = Measure-Transcript $p
}

Write-Output ''
Write-Output ('{0,-14} {1,7} {2,12} {3,12} {4,12} {5,10}' -f 'session', 'turns', 'unique-in', 'cache-read', 'total-in', 'output')
Write-Output ('-' * 72)
foreach ($k in $results.Keys) {
  $r = $results[$k]
  Write-Output ('{0,-14} {1,7} {2,12:N0} {3,12:N0} {4,12:N0} {5,10:N0}' -f $k, $r.turns, $r.unique_input, $r.cache_read, $r.total_input, $r.output)
}

# pairwise comparison on unique input (the per-task ingestion metric).
# the reference is the session whose label contains "base"; else the first one.
$keys = @($results.Keys)
if ($keys.Count -ge 2) {
  $refKey = ($keys | Where-Object { $_ -match '(?i)base' } | Select-Object -First 1)
  if (-not $refKey) { $refKey = $keys[0] }
  $ref = $results[$refKey]
  Write-Output ''
  Write-Output ("reference (baseline) = '{0}'  (unique input {1:N0})" -f $refKey, $ref.unique_input)
  foreach ($k in $keys) {
    if ($k -eq $refKey) { continue }
    $r = $results[$k]
    if ($r.unique_input -gt 0 -and $ref.unique_input -gt 0) {
      $ratio = [math]::Round($ref.unique_input / $r.unique_input, 2)
      $pct = [math]::Round(100 * (1 - $r.unique_input / $ref.unique_input), 1)
      $dir = if ($pct -ge 0) { 'fewer' } else { 'MORE' }
      Write-Output ("  '{0}': {1}x {2} unique input ({3}%) vs baseline" -f $k, $ratio, $dir, [math]::Abs($pct))
    }
  }
}
Write-Output ''
