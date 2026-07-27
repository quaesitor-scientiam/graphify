param([switch]$NoPull)

$ErrorActionPreference = 'Stop'
$vlang   = 'S:\repo\vlang'
$graphify = 'S:\vProjects\graphify\bin\graphify.exe'
$store   = 'S:\graph_data'
$log     = 'S:\graph_data\update.log'

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
