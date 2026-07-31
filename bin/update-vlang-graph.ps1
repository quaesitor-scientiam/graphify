param([switch]$NoPull)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot '..\graphify.config.ps1'
if (-not (Test-Path $configPath)) {
  Write-Error "Missing config: $configPath`nCopy graphify.config.ps1.example to graphify.config.ps1 and edit it for your setup."
  exit 1
}
. $configPath

$vlang    = $GraphifyVlangRepo
$graphify = Join-Path $PSScriptRoot 'graphify.exe'
$store    = $GraphifyStore
$log      = Join-Path $GraphifyStore 'update.log'

function Log($msg) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
  Write-Host $line
  Add-Content $log $line -ErrorAction SilentlyContinue
}

Log "--- vlang graph update start ---"

if (-not $NoPull) {
  Log "git pull..."
  $pull = git -C $vlang pull --ff-only 2>&1
  Log $pull
  if ($pull -match 'Already up to date') {
    Log "No new commits. Skipping extract."
    Log "--- done ---"
    exit 0
  }
}

Log "extracting graph..."
$t = Measure-Command {
  & $graphify extract $vlang --store $store 2>&1 | ForEach-Object { Log $_ }
}
Log "done in $([int]$t.TotalSeconds)s"
Log "--- done ---"
