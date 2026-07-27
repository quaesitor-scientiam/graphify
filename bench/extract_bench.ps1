# bench/extract_bench.ps1 — time a full extraction run against a target repo
#
# Usage:
#   .\extract_bench.ps1                        # defaults: vlang repo, temp out dir
#   .\extract_bench.ps1 -Source S:\repo\vlang -Runs 3
#   .\extract_bench.ps1 -Source S:\myproject -Out S:\temp\gf-bench-myproject
#
# Output: one result line per run, then a summary with min/avg/max.

param(
    [string]$Source = 'S:\repo\vlang',
    [string]$Out    = 'S:\temp\gf-bench',
    [string]$Exe    = 'S:\vProjects\graphify\bin\graphify.exe',
    [int]   $Runs   = 1
)

if (-not (Test-Path $Exe)) {
    Write-Error "graphify.exe not found at: $Exe"
    exit 1
}
if (-not (Test-Path $Source)) {
    Write-Error "Source path not found: $Source"
    exit 1
}

$version = & $Exe --help 2>&1 | Select-Object -First 1
Write-Host "Exe  : $Exe"
Write-Host "Src  : $Source"
Write-Host "Out  : $Out"
Write-Host "Runs : $Runs"
Write-Host ""

$times = @()

for ($i = 1; $i -le $Runs; $i++) {
    # clear output dir so each run starts cold
    if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
    New-Item -ItemType Directory -Path $Out -Force | Out-Null

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & $Exe extract $Source --out $Out 2>&1
    $sw.Stop()

    $secs   = [int]$sw.Elapsed.TotalSeconds
    $times += $secs

    # parse symbol/edge counts from the "extracted N symbols, M edges" line
    $summary = $result | Where-Object { $_ -match 'extracted' } | Select-Object -First 1
    $graphMB = if (Test-Path "$Out\graph.json") {
        '{0:F1} MB' -f ((Get-Item "$Out\graph.json").Length / 1MB)
    } else { 'no graph.json' }

    Write-Host "Run $i : ${secs}s   $summary   graph=$graphMB"
}

if ($Runs -gt 1) {
    $min = ($times | Measure-Object -Minimum).Minimum
    $max = ($times | Measure-Object -Maximum).Maximum
    $avg = [int](($times | Measure-Object -Sum).Sum / $Runs)
    Write-Host ""
    Write-Host "min=${min}s  avg=${avg}s  max=${max}s"
}
